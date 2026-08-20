//! One completed recognition, owned and immutable.
//!
//! Deliberately runtime-neutral: it holds evidence a decoder produced, with no
//! reference to whisper.cpp, so a future Core ML or ONNX adapter can fill the
//! same type. Building one is the adapter's job.
//!
//! Two ownership rules make this safe to hand across a C ABI:
//!
//!   * All text lives in a single NUL-terminated allocation. Segments carry
//!     byte ranges into it rather than their own strings, so a hundred segments
//!     cost one allocation, not a hundred.
//!   * Nothing here borrows from the decoder context. Once built, the value
//!     stays valid — and readable from another thread — while the next
//!     transcription runs on the same transcriber.
//!
//! Every metric is optional. A decoder that did not produce one must say so
//! rather than substitute a plausible number: zero reads as "certain" for a log
//! probability and as "definitely speech" for a no-speech probability, so the
//! wrong default silently inverts the caller's decision.

const std = @import("std");

const Recognition = @This();

allocator: std.mem.Allocator,
/// Every segment's text concatenated, in decode order, NUL-terminated.
text: [:0]u8,
segments: []const Segment,
/// Language the decoder reported, e.g. "en". Empty when it reported none.
language: [:0]u8,
metrics: Metrics,

/// A byte range into `text`.
pub const Range = struct {
    offset: usize,
    len: usize,

    pub fn slice(self: Range, text: []const u8) []const u8 {
        return text[self.offset..][0..self.len];
    }
};

/// Whole-transcript aggregates. Each reduction is documented because the choice
/// is not neutral: a caller comparing against a threshold needs to know what it
/// is comparing.
pub const Metrics = struct {
    /// Mean log probability over every non-special token in every segment.
    /// Token-weighted, so a long confident segment outweighs a short one.
    average_log_probability: ?f32,
    /// The single least likely token anywhere in the transcript. This is what
    /// separates "one misheard word" from "uniformly weak decoding".
    minimum_token_probability: ?f32,
    /// The strongest no-speech evidence any segment produced, i.e. the maximum.
    /// A transcript is suspect if *any* part of it looks like silence; callers
    /// wanting to know which part walk the segments.
    no_speech_probability: ?f32,
};

pub const Segment = struct {
    text_range: Range,
    /// Null unless the decoder was asked for timestamps. Absent is reported
    /// rather than approximated: without timestamp tokens the only bounds
    /// available are those of the decode window, which say nothing about where
    /// the words are.
    start_ms: ?i64,
    end_ms: ?i64,
    /// Mean log probability over this segment's non-special tokens.
    average_log_probability: ?f32,
    no_speech_probability: ?f32,
};

/// Accumulates one recognition. An adapter appends segment text and token
/// evidence as it walks its decoder's output, then calls `toOwned`; the
/// aggregates fall out of the walk, so nothing is traversed twice.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    segments: std.ArrayListUnmanaged(Segment) = .empty,
    log_probability_sum: f64 = 0,
    token_count: usize = 0,
    minimum_token_probability: ?f32 = null,
    no_speech_probability: ?f32 = null,
    /// Where the segment currently being built starts in `text`.
    segment_offset: usize = 0,
    segment_log_probability_sum: f64 = 0,
    segment_token_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.text.deinit(self.allocator);
        self.segments.deinit(self.allocator);
    }

    pub fn reserveSegments(self: *Builder, count: usize) !void {
        try self.segments.ensureTotalCapacityPrecise(self.allocator, count);
    }

    pub fn appendText(self: *Builder, text: []const u8) !void {
        try self.text.appendSlice(self.allocator, text);
    }

    /// Fold one token's evidence into both the current segment and the
    /// transcript. Special tokens must not reach this: they are the decoder's
    /// own bookkeeping and their probabilities are not about the words.
    pub fn addToken(self: *Builder, probability: f32, log_probability: f32) void {
        self.segment_log_probability_sum += log_probability;
        self.segment_token_count += 1;
        self.log_probability_sum += log_probability;
        self.token_count += 1;
        if (self.minimum_token_probability == null or probability < self.minimum_token_probability.?) {
            self.minimum_token_probability = probability;
        }
    }

    /// Close the segment covering every byte appended since the last call.
    pub fn finishSegment(self: *Builder, bounds: SegmentBounds) !void {
        if (bounds.no_speech_probability) |value| {
            if (self.no_speech_probability == null or value > self.no_speech_probability.?) {
                self.no_speech_probability = value;
            }
        }

        try self.segments.append(self.allocator, .{
            .text_range = .{
                .offset = self.segment_offset,
                .len = self.text.items.len - self.segment_offset,
            },
            .start_ms = bounds.start_ms,
            .end_ms = bounds.end_ms,
            .average_log_probability = mean(self.segment_log_probability_sum, self.segment_token_count),
            .no_speech_probability = bounds.no_speech_probability,
        });

        self.segment_offset = self.text.items.len;
        self.segment_log_probability_sum = 0;
        self.segment_token_count = 0;
    }

    /// Transfer ownership of the accumulated buffers. The builder is left empty,
    /// so calling `deinit` afterwards is harmless either way.
    pub fn toOwned(self: *Builder, language: []const u8) !Recognition {
        const owned_language = try self.allocator.dupeZ(u8, language);
        errdefer self.allocator.free(owned_language);

        // Always allocates, even for an empty transcript: the sentinel gives a
        // C caller a valid `const char *` to print instead of a null it has to
        // special-case at every use.
        const owned_text = try self.text.toOwnedSliceSentinel(self.allocator, 0);
        errdefer self.allocator.free(owned_text);

        const owned_segments = try self.segments.toOwnedSlice(self.allocator);

        return .{
            .allocator = self.allocator,
            .text = owned_text,
            .segments = owned_segments,
            .language = owned_language,
            .metrics = .{
                .average_log_probability = mean(self.log_probability_sum, self.token_count),
                .minimum_token_probability = self.minimum_token_probability,
                .no_speech_probability = self.no_speech_probability,
            },
        };
    }
};

pub const SegmentBounds = struct {
    start_ms: ?i64 = null,
    end_ms: ?i64 = null,
    no_speech_probability: ?f32 = null,
};

pub fn deinit(self: *Recognition) void {
    self.allocator.free(self.text);
    self.allocator.free(self.segments);
    self.allocator.free(self.language);
    self.* = undefined;
}

fn mean(sum: f64, count: usize) ?f32 {
    if (count == 0) return null;
    return @floatCast(sum / @as(f64, @floatFromInt(count)));
}

/// Reject a decoder-reported probability that is not one. NaN in particular has
/// to be caught here rather than propagated: it survives every comparison as
/// `false`, which would turn a missing value into whichever verdict the
/// caller's threshold test happens to spell.
pub fn validProbability(value: f32) ?f32 {
    if (std.math.isNan(value) or value < 0.0 or value > 1.0) return null;
    return value;
}

/// whisper-style centiseconds to milliseconds. Negative means "not computed".
pub fn centisecondsToMilliseconds(centiseconds: i64) ?i64 {
    if (centiseconds < 0) return null;
    return centiseconds * 10;
}

test "builder produces contiguous text with per-segment ranges" {
    var builder: Builder = .init(std.testing.allocator);
    defer builder.deinit();

    try builder.appendText(" Hello");
    builder.addToken(0.9, -0.1);
    builder.addToken(0.5, -0.7);
    try builder.finishSegment(.{ .start_ms = 0, .end_ms = 500, .no_speech_probability = 0.01 });

    try builder.appendText(" world.");
    builder.addToken(0.8, -0.2);
    try builder.finishSegment(.{ .start_ms = 500, .end_ms = 900, .no_speech_probability = 0.4 });

    var recognition = try builder.toOwned("en");
    defer recognition.deinit();

    try std.testing.expectEqualStrings(" Hello world.", recognition.text);
    try std.testing.expectEqual(@as(usize, 2), recognition.segments.len);
    try std.testing.expectEqualStrings(" Hello", recognition.segments[0].text_range.slice(recognition.text));
    try std.testing.expectEqualStrings(" world.", recognition.segments[1].text_range.slice(recognition.text));
    try std.testing.expectEqualStrings("en", recognition.language);

    // Token-weighted over all three tokens: (-0.1 - 0.7 - 0.2) / 3.
    try std.testing.expectApproxEqAbs(
        @as(f32, -1.0 / 3.0),
        recognition.metrics.average_log_probability.?,
        1e-6,
    );
    // Per segment: the first averages its own two tokens, not the transcript's.
    try std.testing.expectApproxEqAbs(
        @as(f32, -0.4),
        recognition.segments[0].average_log_probability.?,
        1e-6,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), recognition.metrics.minimum_token_probability.?, 1e-6);
    // The maximum, not the last or the mean.
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), recognition.metrics.no_speech_probability.?, 1e-6);
}

test "a transcript with no tokens reports absent metrics, not zeroes" {
    var builder: Builder = .init(std.testing.allocator);
    defer builder.deinit();

    var recognition = try builder.toOwned("");
    defer recognition.deinit();

    try std.testing.expectEqualStrings("", recognition.text);
    try std.testing.expectEqual(@as(usize, 0), recognition.segments.len);
    try std.testing.expect(recognition.metrics.average_log_probability == null);
    try std.testing.expect(recognition.metrics.minimum_token_probability == null);
    try std.testing.expect(recognition.metrics.no_speech_probability == null);
    // Still a printable C string.
    try std.testing.expectEqual(@as(u8, 0), recognition.text.ptr[0]);
}

test "an empty segment keeps a zero-length range rather than shifting the next" {
    var builder: Builder = .init(std.testing.allocator);
    defer builder.deinit();

    try builder.finishSegment(.{});
    try builder.appendText("text");
    try builder.finishSegment(.{});

    var recognition = try builder.toOwned("en");
    defer recognition.deinit();

    try std.testing.expectEqual(@as(usize, 0), recognition.segments[0].text_range.len);
    try std.testing.expectEqual(@as(usize, 0), recognition.segments[1].text_range.offset);
    try std.testing.expectEqualStrings("text", recognition.segments[1].text_range.slice(recognition.text));
}

test "probabilities outside the unit range are treated as absent" {
    try std.testing.expectEqual(@as(?f32, 0.25), validProbability(0.25));
    try std.testing.expectEqual(@as(?f32, 0.0), validProbability(0.0));
    try std.testing.expectEqual(@as(?f32, 1.0), validProbability(1.0));
    try std.testing.expect(validProbability(std.math.nan(f32)) == null);
    try std.testing.expect(validProbability(-1.0) == null);
    try std.testing.expect(validProbability(1.5) == null);
}

test "negative centiseconds mean not computed" {
    try std.testing.expectEqual(@as(?i64, 0), centisecondsToMilliseconds(0));
    try std.testing.expectEqual(@as(?i64, 1230), centisecondsToMilliseconds(123));
    try std.testing.expect(centisecondsToMilliseconds(-1) == null);
}
