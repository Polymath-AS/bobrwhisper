//! Conservative, deterministic transcript cleanup and LLM-output validation.

const std = @import("std");

pub const Mode = enum(c_int) { literal = 0, conservative = 1, polish = 2 };
pub const LlmOutcome = enum { accepted, timeout, stale_revision, invalid_output };
pub const llm_deadline_ms: u64 = 2000;
pub const clause_llm_deadline_ms: u64 = 750;
pub const DeterministicResult = struct {
    text: []u8,
    resolved_correction: bool,
};

pub fn evaluateLlm(elapsed_ms: i128, revision_is_current: bool, output_is_valid: bool) LlmOutcome {
    if (elapsed_ms > llm_deadline_ms) return .timeout;
    if (!revision_is_current) return .stale_revision;
    if (!output_is_valid) return .invalid_output;
    return .accepted;
}

pub fn deterministic(allocator: std.mem.Allocator, input: []const u8, mode: Mode) ![]u8 {
    return (try deterministicDetailed(allocator, input, mode)).text;
}

pub fn deterministicDetailed(allocator: std.mem.Allocator, input: []const u8, mode: Mode) !DeterministicResult {
    if (mode == .literal) return .{
        .text = try allocator.dupe(u8, std.mem.trim(u8, input, " \t\r\n")),
        .resolved_correction = false,
    };

    const corrected = try resolveExplicitCorrections(allocator, input);
    defer allocator.free(corrected.text);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    var tokens = std.mem.tokenizeAny(u8, corrected.text, " \t\r\n");
    while (tokens.next()) |token| {
        const bare = std.mem.trim(u8, token, ",.!?;:—-");
        if (isFiller(bare)) continue;
        if (output.items.len != 0 and !isClosingPunctuation(token)) try output.append(allocator, ' ');
        try output.appendSlice(allocator, token);
    }

    output.items.len = normalizePunctuation(output.items);
    const trimmed = std.mem.trim(u8, output.items, " \t\r\n");
    const result = try allocator.dupe(u8, trimmed);
    output.deinit(allocator);
    return .{ .text = result, .resolved_correction = corrected.resolved_correction };
}

const CorrectionToken = struct {
    text: []const u8,
    explicit_cue: bool = false,
};

const CorrectionResult = struct {
    text: []u8,
    resolved_correction: bool,
};

/// Resolve bounded, explicit self-corrections without asking the LLM to infer
/// which fact the speaker rejected. This deliberately handles only strong
/// cues, such as "Wednesday? Sorry, Friday", "Wednesday? No, sorry, Friday",
/// "Wednesday? I mean Thursday", and "Tuesday—actually Wednesday".
fn resolveExplicitCorrections(allocator: std.mem.Allocator, input: []const u8) !CorrectionResult {
    var tokens: std.ArrayListUnmanaged(CorrectionToken) = .empty;
    defer tokens.deinit(allocator);

    var source = std.mem.tokenizeAny(u8, input, " \t\r\n");
    while (source.next()) |token| {
        if (inlineCueAfterDash(token)) |dash_index| {
            if (dash_index > 0) try tokens.append(allocator, .{ .text = token[0..dash_index] });
            try tokens.append(allocator, .{
                .text = token[dash_index + "—".len ..],
                .explicit_cue = true,
            });
        } else if (structuralCorrectionDash(tokens.items, token)) |dash_index| {
            try tokens.append(allocator, .{ .text = token[0..dash_index] });
            try tokens.append(allocator, .{ .text = token[dash_index + "—".len ..] });
        } else {
            try tokens.append(allocator, .{ .text = token });
        }
    }

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    var last_token_start: ?usize = null;
    var resolved_correction = false;
    var index: usize = 0;
    while (index < tokens.items.len) {
        if (last_token_start != null) {
            // Postfix form: "Wednesday? Thursday instead."
            if (index + 1 < tokens.items.len and
                trailingTerminal(output.items[last_token_start.?..]) != null and
                equalsBare(tokens.items[index + 1].text, "instead") and
                isBoundedPostfixCue(tokens.items, index + 1))
            {
                try replaceLastToken(
                    &output,
                    allocator,
                    last_token_start.?,
                    tokens.items[index].text,
                );
                resolved_correction = true;
                index += 2;
                continue;
            }

            if (correctionCueEnd(tokens.items, index, output.items[last_token_start.?..])) |cue_end| {
                var replacement_index = cue_end;
                if (replacement_index + 1 < tokens.items.len and
                    equalsBare(tokens.items[replacement_index].text, "make") and
                    equalsBare(tokens.items[replacement_index + 1].text, "that"))
                {
                    replacement_index += 2;
                }
                if (replacement_index < tokens.items.len) {
                    replaceLastToken(
                        &output,
                        allocator,
                        last_token_start.?,
                        tokens.items[replacement_index].text,
                    ) catch |err| return err;
                    resolved_correction = true;
                    index = replacement_index + 1;
                    continue;
                }
            }
        }

        if (output.items.len != 0 and output.items[output.items.len - 1] != ' ') {
            try output.append(allocator, ' ');
        }
        last_token_start = output.items.len;
        try output.appendSlice(allocator, tokens.items[index].text);
        index += 1;
    }

    const result = try allocator.dupe(u8, output.items);
    output.deinit(allocator);
    return .{ .text = result, .resolved_correction = resolved_correction };
}

fn correctionCueEnd(
    tokens: []const CorrectionToken,
    index: usize,
    previous_token: []const u8,
) ?usize {
    const token = tokens[index];
    const bare = std.mem.trim(u8, token.text, ",.!?;:—-");
    if (token.explicit_cue and isInlineCorrectionCue(bare) and
        isBoundedReplacement(tokens, index + 1))
    {
        return index + 1;
    }

    if (std.ascii.eqlIgnoreCase(bare, "correction") and
        (trailingTerminal(previous_token) != null or std.mem.endsWith(u8, previous_token, ",")) and
        isBoundedReplacement(tokens, index + 1))
    {
        return index + 1;
    }
    if ((std.ascii.eqlIgnoreCase(bare, "actually") or std.ascii.eqlIgnoreCase(bare, "rather")) and
        (trailingTerminal(previous_token) != null or std.mem.endsWith(u8, previous_token, ",")) and
        isBoundedReplacement(tokens, index + 1))
    {
        return index + 1;
    }

    if (std.ascii.eqlIgnoreCase(bare, "no") and trailingTerminal(previous_token) != null and
        index + 1 < tokens.len and equalsBare(tokens[index + 1].text, "sorry"))
    {
        if (isBoundedReplacement(tokens, index + 2)) return index + 2;
    }
    if (std.ascii.eqlIgnoreCase(bare, "no") and trailingTerminal(previous_token) != null and
        isBoundedReplacement(tokens, index + 1))
    {
        return index + 1;
    }
    if (std.ascii.eqlIgnoreCase(bare, "sorry") and trailingTerminal(previous_token) != null and
        isBoundedReplacement(tokens, index + 1))
    {
        return index + 1;
    }
    if (std.ascii.eqlIgnoreCase(bare, "i") and trailingTerminal(previous_token) != null and
        index + 2 < tokens.len and
        (equalsBare(tokens[index + 1].text, "mean") or equalsBare(tokens[index + 1].text, "meant")) and
        isBoundedReplacement(tokens, index + 2))
    {
        return index + 2;
    }
    if (std.ascii.eqlIgnoreCase(bare, "or") and trailingTerminal(previous_token) != null and
        index + 1 < tokens.len and equalsBare(tokens[index + 1].text, "rather") and
        isBoundedReplacement(tokens, index + 2))
    {
        return index + 2;
    }
    if (std.ascii.eqlIgnoreCase(bare, "make") and trailingTerminal(previous_token) != null and
        index + 1 < tokens.len and equalsBare(tokens[index + 1].text, "that") and
        isBoundedReplacement(tokens, index + 2))
    {
        return index + 2;
    }
    if (std.ascii.eqlIgnoreCase(bare, "scratch") and trailingTerminal(previous_token) != null and
        index + 1 < tokens.len and equalsBare(tokens[index + 1].text, "that") and
        isBoundedReplacement(tokens, index + 2))
    {
        return index + 2;
    }
    if (std.ascii.eqlIgnoreCase(bare, "better") and trailingTerminal(previous_token) != null and
        index + 1 < tokens.len and equalsBare(tokens[index + 1].text, "yet") and
        isBoundedReplacement(tokens, index + 2))
    {
        return index + 2;
    }
    if (std.ascii.eqlIgnoreCase(bare, "let") and trailingTerminal(previous_token) != null and
        index + 3 < tokens.len and
        equalsBare(tokens[index + 1].text, "me") and
        equalsBare(tokens[index + 2].text, "correct") and
        equalsBare(tokens[index + 3].text, "that") and
        isBoundedReplacement(tokens, index + 4))
    {
        return index + 4;
    }
    if (std.ascii.eqlIgnoreCase(bare, "not") and
        (trailingTerminal(previous_token) != null or std.mem.endsWith(u8, previous_token, ",")) and
        index + 2 < tokens.len and
        sameBareToken(previous_token, tokens[index + 1].text) and
        isBoundedReplacement(tokens, index + 2))
    {
        return index + 2;
    }
    return null;
}

fn isBoundedReplacement(tokens: []const CorrectionToken, index: usize) bool {
    if (index >= tokens.len) return false;
    return index + 1 == tokens.len or trailingTerminal(tokens[index].text) != null;
}

fn isBoundedPostfixCue(tokens: []const CorrectionToken, cue_index: usize) bool {
    if (cue_index >= tokens.len) return false;
    return cue_index + 1 == tokens.len or trailingTerminal(tokens[cue_index].text) != null;
}

fn replaceLastToken(
    output: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    token_start: usize,
    replacement_raw: []const u8,
) !void {
    const old_token = output.items[token_start..];
    const terminal = trailingTerminal(old_token);
    output.items.len = token_start;

    const replacement = if (terminal != null)
        std.mem.trimEnd(u8, replacement_raw, ",.!?;:")
    else
        replacement_raw;
    try output.appendSlice(allocator, replacement);
    if (terminal) |punctuation| try output.append(allocator, punctuation);
}

fn trailingTerminal(token: []const u8) ?u8 {
    if (token.len == 0) return null;
    const last = token[token.len - 1];
    return switch (last) {
        '.', '!', '?' => last,
        else => null,
    };
}

fn equalsBare(token: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, ",.!?;:—-"), expected);
}

fn sameBareToken(left: []const u8, right: []const u8) bool {
    const punctuation = ",.!?;:—-";
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, left, punctuation),
        std.mem.trim(u8, right, punctuation),
    );
}

fn inlineCueAfterDash(token: []const u8) ?usize {
    const dash_index = std.mem.indexOf(u8, token, "—") orelse return null;
    const cue_start = dash_index + "—".len;
    if (cue_start >= token.len) return null;
    const cue = std.mem.trim(u8, token[cue_start..], ",.!?;:—-");
    return if (isInlineCorrectionCue(cue)) dash_index else null;
}

fn structuralCorrectionDash(tokens: []const CorrectionToken, token: []const u8) ?usize {
    const dash_index = std.mem.indexOf(u8, token, "—") orelse return null;
    const suffix_start = dash_index + "—".len;
    if (dash_index == 0 or suffix_start >= token.len or tokens.len == 0) return null;

    const prefix = std.mem.trim(u8, token[0..dash_index], ",.!?;:—-");
    const previous = tokens[tokens.len - 1].text;
    if (std.ascii.eqlIgnoreCase(prefix, "that")) {
        if (equalsBare(previous, "make") or equalsBare(previous, "scratch")) return dash_index;
        if (tokens.len >= 3 and
            equalsBare(tokens[tokens.len - 3].text, "let") and
            equalsBare(tokens[tokens.len - 2].text, "me") and
            equalsBare(previous, "correct"))
        {
            return dash_index;
        }
    }
    if (equalsBare(previous, "not")) return dash_index;
    return null;
}

pub fn validateLlmOutput(input: []const u8, candidate_raw: []const u8) bool {
    const candidate = std.mem.trim(u8, candidate_raw, " \t\r\n\"`");
    if (candidate.len == 0 or candidate.len > input.len * 3 + 64) return false;
    const lowered_prefixes = [_][]const u8{ "here is", "sure", "output:", "rewritten", "note:" };
    for (lowered_prefixes) |prefix| {
        if (startsWithIgnoreCase(candidate, prefix)) return false;
    }

    var protected = std.mem.tokenizeAny(u8, input, " \t\r\n");
    var token_index: usize = 0;
    while (protected.next()) |raw_token| {
        defer token_index += 1;
        const token = std.mem.trim(u8, raw_token, ",.;!?()[]{}<>\"'`—");
        if (!isProtectedAtPosition(token, token_index)) continue;
        if (!containsProtectedToken(candidate, token)) return false;
    }
    return true;
}

pub fn validateLlmOutputForMode(input: []const u8, candidate: []const u8, mode: Mode) bool {
    if (!validateLlmOutput(input, candidate)) return false;
    return mode != .conservative or hasSameWordSequence(input, candidate);
}

fn hasSameWordSequence(input: []const u8, candidate: []const u8) bool {
    const delimiters = " \t\r\n,.;:!?()[]{}<>\"'—-";
    var input_words = std.mem.tokenizeAny(u8, input, delimiters);
    var candidate_words = std.mem.tokenizeAny(u8, candidate, delimiters);
    while (input_words.next()) |input_word| {
        const candidate_word = candidate_words.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(input_word, candidate_word)) return false;
    }
    return candidate_words.next() == null;
}

pub fn isProtected(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |ch| if (std.ascii.isDigit(ch)) return true;
    return std.mem.startsWith(u8, token, "http://") or std.mem.startsWith(u8, token, "https://") or
        std.mem.indexOfAny(u8, token, "_/@\\") != null or hasLowerThenUpper(token) or
        isAcronym(token) or isProperNounLike(token);
}

fn isProtectedAtPosition(token: []const u8, token_index: usize) bool {
    if (!isProtected(token)) return false;
    // Capitalization alone is ambiguous for the first word of a sentence
    // ("Could" -> "Can" is a valid polish). Intrinsically identifiable
    // entities remain protected in that position.
    if (token_index != 0 or !isProperNounLike(token)) return true;
    return !isCommonSentenceStarter(token) or isAcronym(token) or isKnownCalendarWord(token) or
        std.mem.indexOfAny(u8, token, "_/@\\") != null or hasLowerThenUpper(token);
}

fn isCommonSentenceStarter(token: []const u8) bool {
    const values = [_][]const u8{
        "A",   "An",     "The",   "I",    "We", "You", "It",   "This", "That",
        "Can", "Could",  "Would", "Will", "Do", "Did", "Have", "Has",  "Is",
        "Are", "Please", "Let",
    };
    for (values) |value| if (std.mem.eql(u8, token, value)) return true;
    return false;
}

fn isKnownCalendarWord(token: []const u8) bool {
    const values = [_][]const u8{
        "Monday",  "Tuesday",   "Wednesday", "Thursday", "Friday",   "Saturday", "Sunday",
        "January", "February",  "March",     "April",    "May",      "June",     "July",
        "August",  "September", "October",   "November", "December",
    };
    for (values) |value| if (std.mem.eql(u8, token, value)) return true;
    return false;
}

fn containsProtectedToken(candidate: []const u8, protected: []const u8) bool {
    if (std.mem.startsWith(u8, protected, "http://") or
        std.mem.startsWith(u8, protected, "https://"))
    {
        return std.mem.indexOf(u8, candidate, protected) != null;
    }

    var words = std.mem.tokenizeAny(u8, candidate, " \t\r\n");
    while (words.next()) |raw_word| {
        const word = std.mem.trim(u8, raw_word, ",.;!?()[]{}<>\"'`—");
        if (std.mem.eql(u8, word, protected)) return true;
    }
    return false;
}

fn isAcronym(token: []const u8) bool {
    var letters: usize = 0;
    for (token) |ch| {
        if (std.ascii.isAlphabetic(ch)) {
            if (!std.ascii.isUpper(ch)) return false;
            letters += 1;
        } else if (ch != '-' and ch != '.') return false;
    }
    return letters >= 2;
}

fn isProperNounLike(token: []const u8) bool {
    if (token.len < 2 or !std.ascii.isUpper(token[0])) return false;
    var lowercase_letters: usize = 0;
    for (token[1..]) |ch| if (std.ascii.isLower(ch)) {
        lowercase_letters += 1;
    };
    return lowercase_letters > 0;
}

fn isFiller(word: []const u8) bool {
    const fillers = [_][]const u8{ "um", "uh", "erm", "hmm" };
    for (fillers) |filler| if (std.ascii.eqlIgnoreCase(word, filler)) return true;
    return false;
}

fn isCorrectionCue(word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(word, "actually") or std.ascii.eqlIgnoreCase(word, "correction");
}

fn isInlineCorrectionCue(word: []const u8) bool {
    return isCorrectionCue(word) or
        std.ascii.eqlIgnoreCase(word, "no") or
        std.ascii.eqlIgnoreCase(word, "sorry") or
        std.ascii.eqlIgnoreCase(word, "rather");
}

fn isClosingPunctuation(token: []const u8) bool {
    return token.len == 1 and std.mem.indexOfScalar(u8, ",.!?;:", token[0]) != null;
}

fn normalizePunctuation(text: []u8) usize {
    var write: usize = 0;
    var previous_space = false;
    for (text) |ch| {
        if (ch == ' ') {
            if (previous_space) continue;
            previous_space = true;
        } else {
            previous_space = false;
        }
        text[write] = ch;
        write += 1;
    }
    return write;
}

fn hasLowerThenUpper(word: []const u8) bool {
    var lower = false;
    for (word) |ch| {
        if (std.ascii.isLower(ch)) lower = true;
        if (lower and std.ascii.isUpper(ch)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

test "cleanup is idempotent and preserves protected tokens" {
    const once = try deterministic(std.testing.allocator, " um  ship apiURL https://example.test 42 ", .conservative);
    defer std.testing.allocator.free(once);
    const twice = try deterministic(std.testing.allocator, once, .conservative);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);
    try std.testing.expect(std.mem.indexOf(u8, once, "apiURL") != null);
    try std.testing.expect(std.mem.indexOf(u8, once, "42") != null);
}

test "explicit spoken correction replaces the rejected value" {
    const cleaned = try deterministic(
        std.testing.allocator,
        "Could you schedule a meeting for Wednesday? No, sorry, Friday.",
        .conservative,
    );
    defer std.testing.allocator.free(cleaned);
    try std.testing.expectEqualStrings("Could you schedule a meeting for Friday?", cleaned);

    const short_sorry = try deterministic(
        std.testing.allocator,
        "Can you schedule a meeting for Wednesday? Sorry, Friday.",
        .conservative,
    );
    defer std.testing.allocator.free(short_sorry);
    try std.testing.expectEqualStrings("Can you schedule a meeting for Friday?", short_sorry);

    const i_mean = try deterministic(
        std.testing.allocator,
        "Can you book a meeting for Wednesday? I mean Thursday.",
        .conservative,
    );
    defer std.testing.allocator.free(i_mean);
    try std.testing.expectEqualStrings("Can you book a meeting for Thursday?", i_mean);

    const inline_result = try deterministic(std.testing.allocator, "Schedule it Tuesday—actually Wednesday.", .conservative);
    defer std.testing.allocator.free(inline_result);
    try std.testing.expectEqualStrings("Schedule it Wednesday.", inline_result);

    const ordinary_no = try deterministic(std.testing.allocator, "Did you answer yes? No, I said no.", .conservative);
    defer std.testing.allocator.free(ordinary_no);
    try std.testing.expectEqualStrings("Did you answer yes? No, I said no.", ordinary_no);

    const apology = try deterministic(std.testing.allocator, "Are you okay? Sorry, I was late.", .conservative);
    defer std.testing.allocator.free(apology);
    try std.testing.expectEqualStrings("Are you okay? Sorry, I was late.", apology);
}

test "common bounded correction cues replace the rejected value" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "Book it for Wednesday? Actually, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? No, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? I meant Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Rather, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Or rather, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Make that Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Make that—Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Correction: Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Let me correct that, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Let me correct that—Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Scratch that, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Scratch that—Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday? Better yet, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday—no, Thursday.", .expected = "Book it for Thursday." },
        .{ .input = "Book it for Wednesday? Not Wednesday, Thursday.", .expected = "Book it for Thursday?" },
        .{ .input = "Book it for Wednesday, not Wednesday—Thursday.", .expected = "Book it for Thursday." },
        .{ .input = "Book it for Wednesday? Thursday instead.", .expected = "Book it for Thursday?" },
    };
    for (cases) |case| {
        const cleaned = try deterministic(std.testing.allocator, case.input, .conservative);
        defer std.testing.allocator.free(cleaned);
        try std.testing.expectEqualStrings(case.expected, cleaned);
    }

    const ambiguous = try deterministic(
        std.testing.allocator,
        "Book it for Wednesday? Actually, I need to check.",
        .conservative,
    );
    defer std.testing.allocator.free(ambiguous);
    try std.testing.expectEqualStrings(
        "Book it for Wednesday? Actually, I need to check.",
        ambiguous,
    );
}

test "LLM validation rejects commentary and dropped protected entities" {
    try std.testing.expect(!validateLlmOutput("Use apiURL 42", "Here is the rewritten text: Use apiURL 42"));
    try std.testing.expect(!validateLlmOutput("Use apiURL 42", "Use the API"));
    try std.testing.expect(validateLlmOutput("Use apiURL 42", "Use apiURL 42."));
}

test "polish validation rejects changed acronyms and proper nouns" {
    try std.testing.expect(!validateLlmOutputForMode(
        "Meet NASA on Wednesday.",
        "Meet ESA on Thursday.",
        .polish,
    ));
    try std.testing.expect(validateLlmOutputForMode(
        "Meet NASA on Wednesday.",
        "Meet NASA on Wednesday!",
        .polish,
    ));
    try std.testing.expect(!validateLlmOutputForMode(
        "Alice will attend.",
        "Bob will attend.",
        .polish,
    ));
}

test "conservative LLM validation preserves every cleaned word" {
    const input = "Could you schedule a meeting for Friday?";
    try std.testing.expect(validateLlmOutputForMode(
        input,
        "Could you schedule a meeting for Friday.",
        .conservative,
    ));
    try std.testing.expect(!validateLlmOutputForMode(
        input,
        "Can you schedule a meeting for Friday? Sorry.",
        .conservative,
    ));
    try std.testing.expect(!validateLlmOutputForMode(
        input,
        "Friday, could you schedule a meeting for you?",
        .conservative,
    ));
    try std.testing.expect(validateLlmOutputForMode(
        input,
        "Can you schedule a Friday meeting?",
        .polish,
    ));
}

test "LLM timeout invalid and stale paths deterministically fall back" {
    try std.testing.expectEqual(LlmOutcome.accepted, evaluateLlm(llm_deadline_ms, true, true));
    try std.testing.expectEqual(LlmOutcome.timeout, evaluateLlm(llm_deadline_ms + 1, true, true));
    try std.testing.expectEqual(LlmOutcome.stale_revision, evaluateLlm(10, false, true));
    try std.testing.expectEqual(LlmOutcome.invalid_output, evaluateLlm(10, true, false));
}
