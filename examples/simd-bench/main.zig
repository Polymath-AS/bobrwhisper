//! Scalar-versus-vector timings for the loops in `src/audio/simd.zig`.
//!
//! The scalar functions below are the originals those helpers replaced, kept
//! verbatim so the comparison stays honest. The lane count — and therefore the
//! ceiling on the speedup — is a property of the host CPU, so run this on the
//! machine you care about:
//!
//!     zig build bench-simd -Doptimize=ReleaseFast
//!
//! Debug builds measure the absence of optimization, not the vectorization;
//! the step forces ReleaseFast for that reason.

const std = @import("std");
const simd = @import("simd");

/// 30 s at 16 kHz — a long dictation, and past every cache level, so the
/// numbers include the memory traffic a real recording pays for.
const sample_count = 480_000;
const reps = 200;

fn nanos() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds());
}

// ---- the scalar originals ----

fn scalarSumOfSquares(samples: []const f32) f32 {
    var energy: f32 = 0;
    for (samples) |s| energy += s * s;
    return energy;
}

fn scalarEnergy(samples: []const f32) struct { f32, bool } {
    var energy: f32 = 0;
    var any_nonzero = false;
    for (samples) |s| {
        energy += s * s;
        if (s != 0) any_nonzero = true;
    }
    return .{ energy, any_nonzero };
}

fn scalarMaxAbs(samples: []const f32) f32 {
    var peak: f32 = 0;
    for (samples) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
    }
    return peak;
}

fn scalarScale(samples: []f32, gain: f32) void {
    for (samples) |*s| s.* *= gain;
}

fn scalarScaleClamped(samples: []f32, gain: f32) void {
    for (samples) |*s| s.* = std.math.clamp(s.* * gain, -1.0, 1.0);
}

fn scalarQuantize(samples: []const f32, out: []i16) void {
    for (samples, out[0..samples.len]) |s, *o| {
        o.* = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 32767.0);
    }
}

fn scalarDequantize(raw: []const u8, frame_bytes: usize, out: []f32) void {
    for (0..raw.len / frame_bytes) |i| {
        const q = std.mem.readInt(i16, raw[i * frame_bytes ..][0..2], .little);
        out[i] = @as(f32, @floatFromInt(q)) / 32768.0;
    }
}

/// `computeAudioStats` before the change: peak and the f64 energy fused into
/// one pass. The vector version below splits it into two passes, so this row
/// is the one that answers whether that split cost more than it bought.
fn scalarStats(samples: []const f32) struct { f32, f64 } {
    var peak: f32 = 0;
    var energy: f64 = 0;
    for (samples) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
        energy += @as(f64, s) * @as(f64, s);
    }
    return .{ peak, energy };
}

fn vectorStats(samples: []const f32) struct { f32, f64 } {
    return .{ simd.maxAbs(samples), simd.sumOfSquaresWide(samples) };
}

/// The shape `trimSilenceBounds` actually runs: a 160-sample window advancing
/// by 80, so every sample is squared twice.
fn windowScan(samples: []const f32, comptime vectorized: bool) usize {
    const window: usize = 160;
    var hits: usize = 0;
    var i: usize = 0;
    while (i + window < samples.len) : (i += window / 2) {
        const e = if (vectorized)
            simd.sumOfSquares(samples[i..][0..window])
        else
            scalarSumOfSquares(samples[i..][0..window]);
        if (e / @as(f32, window) > 1e9) hits += 1;
    }
    return hits;
}

fn report(name: []const u8, scalar_ns: u64, vector_ns: u64) void {
    std.debug.print("{s: <22} scalar {d: >7.2} ms   simd {d: >7.2} ms   {d: >5.2}x\n", .{
        name,
        @as(f64, @floatFromInt(scalar_ns)) / 1e6,
        @as(f64, @floatFromInt(vector_ns)) / 1e6,
        @as(f64, @floatFromInt(scalar_ns)) / @as(f64, @floatFromInt(vector_ns)),
    });
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();

    const samples = try gpa.alloc(f32, sample_count);
    defer gpa.free(samples);
    const scratch = try gpa.alloc(f32, sample_count);
    defer gpa.free(scratch);
    const quantized = try gpa.alloc(i16, sample_count);
    defer gpa.free(quantized);
    const raw = try gpa.alloc(u8, sample_count * 2);
    defer gpa.free(raw);

    var prng = std.Random.DefaultPrng.init(0xfeedface);
    const rand = prng.random();
    // Spread past ±1.0 so the clamping paths reach their clamps.
    for (samples) |*s| s.* = rand.float(f32) * 1.6 - 0.8;
    for (raw) |*b| b.* = rand.int(u8);

    std.debug.print("{d} samples/pass, {d} reps, {?d} f32 lanes\n\n", .{
        sample_count,
        reps,
        std.simd.suggestVectorLength(f32),
    });

    {
        var start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(scalarSumOfSquares(samples));
        const scalar_ns = nanos() - start;
        start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(simd.sumOfSquares(samples));
        report("sumOfSquares", scalar_ns, nanos() - start);
    }

    {
        var start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(scalarEnergy(samples));
        const scalar_ns = nanos() - start;
        start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(simd.energy(samples));
        report("energy (callback)", scalar_ns, nanos() - start);
    }

    {
        var start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(windowScan(samples, false));
        const scalar_ns = nanos() - start;
        start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(windowScan(samples, true));
        report("trimSilence scan", scalar_ns, nanos() - start);
    }

    {
        var start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(scalarMaxAbs(samples));
        const scalar_ns = nanos() - start;
        start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(simd.maxAbs(samples));
        report("maxAbs", scalar_ns, nanos() - start);
    }

    {
        @memcpy(scratch, samples);
        var start = nanos();
        for (0..reps) |_| {
            scalarScale(scratch, 1.0000001);
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        const scalar_ns = nanos() - start;
        @memcpy(scratch, samples);
        start = nanos();
        for (0..reps) |_| {
            simd.scale(scratch, 1.0000001);
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        report("scale", scalar_ns, nanos() - start);
    }

    {
        @memcpy(scratch, samples);
        var start = nanos();
        for (0..reps) |_| {
            scalarScaleClamped(scratch, 1.0000001);
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        const scalar_ns = nanos() - start;
        @memcpy(scratch, samples);
        start = nanos();
        for (0..reps) |_| {
            simd.scaleClamped(scratch, 1.0000001);
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        report("scaleClamped", scalar_ns, nanos() - start);
    }

    {
        var start = nanos();
        for (0..reps) |_| {
            scalarQuantize(samples, quantized);
            std.mem.doNotOptimizeAway(quantized.ptr);
        }
        const scalar_ns = nanos() - start;
        start = nanos();
        for (0..reps) |_| {
            simd.quantizeToI16(samples, quantized);
            std.mem.doNotOptimizeAway(quantized.ptr);
        }
        report("quantizeToI16", scalar_ns, nanos() - start);
    }

    {
        var start = nanos();
        for (0..reps) |_| {
            scalarDequantize(raw, 2, scratch);
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        const scalar_ns = nanos() - start;
        start = nanos();
        for (0..reps) |_| {
            simd.dequantizeFromI16(raw, 2, scratch);
            std.mem.doNotOptimizeAway(scratch.ptr);
        }
        report("dequantizeFromI16", scalar_ns, nanos() - start);
    }

    {
        var start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(scalarStats(samples));
        const scalar_ns = nanos() - start;
        start = nanos();
        for (0..reps) |_| std.mem.doNotOptimizeAway(vectorStats(samples));
        report("audioStats 1 vs 2 pass", scalar_ns, nanos() - start);
    }
}
