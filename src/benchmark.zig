//! Benchmark suite for the Zig Dependency Injection library
//!
//! Run with: zig build bench
//!
//! Benchmarks:
//! - Container initialization
//! - Service registration
//! - Singleton resolution
//! - Transient resolution
//! - Scoped resolution
//! - Injected dependency resolution
//! - Lazy dependency resolution
//! - Custom factory resolution
//! - Named registration and resolution
//! - Scope creation and destruction

const std = @import("std");
const Allocator = std.mem.Allocator;

const di = @import("root.zig");

// ============================================================================
// Test Services
// ============================================================================

const SimpleService = struct {
    value: u64 = 42,
};

const ServiceWithDeinit = struct {
    value: u64 = 0,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

const DependencyA = struct {
    id: u64 = 1,
};

const DependencyB = struct {
    id: u64 = 2,
};

const DependencyC = struct {
    id: u64 = 3,
};

const ServiceWithInjected = struct {
    dep_a: di.Injected(DependencyA),
    dep_b: di.Injected(DependencyB),
    value: u64 = 100,
};

const ServiceWithLazy = struct {
    dep_a: di.Lazy(DependencyA),
    dep_b: di.Lazy(DependencyB),
    value: u64 = 200,
};

const ServiceWithMixedDeps = struct {
    eager: di.Injected(DependencyA),
    lazy: di.Lazy(DependencyB),
    value: u64 = 300,
};

const DeepDependencyChain = struct {
    dep: di.Injected(ServiceWithInjected),
    value: u64 = 400,
};

const ComplexService = struct {
    dep_a: di.Injected(DependencyA),
    dep_b: di.Injected(DependencyB),
    dep_c: di.Injected(DependencyC),
    lazy_a: di.Lazy(DependencyA),
    value: u64 = 500,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

// ============================================================================
// Benchmark Infrastructure
// ============================================================================

const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    max_ns: u64,
    ops_per_sec: u64,
};

fn formatNs(ns: u64) struct { value: f64, unit: []const u8 } {
    if (ns >= 1_000_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0, .unit = "s" };
    } else if (ns >= 1_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000_000.0, .unit = "ms" };
    } else if (ns >= 1_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000.0, .unit = "us" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(ns)), .unit = "ns" };
    }
}

fn formatOps(ops: u64) struct { value: f64, unit: []const u8 } {
    if (ops >= 1_000_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ops)) / 1_000_000_000.0, .unit = "B" };
    } else if (ops >= 1_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ops)) / 1_000_000.0, .unit = "M" };
    } else if (ops >= 1_000) {
        return .{ .value = @as(f64, @floatFromInt(ops)) / 1_000.0, .unit = "K" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(ops)), .unit = "" };
    }
}

fn printResult(result: BenchmarkResult) void {
    const avg = formatNs(result.avg_ns);
    const min = formatNs(result.min_ns);
    const max = formatNs(result.max_ns);
    const ops = formatOps(result.ops_per_sec);

    std.debug.print("  {s:<42} avg: {d:>6.2}{s:<2}  (min: {d:>6.2}{s:<2}, max: {d:>6.2}{s:<2})  {d:>6.2}{s} ops/sec\n", .{
        result.name,
        avg.value,
        avg.unit,
        min.value,
        min.unit,
        max.value,
        max.unit,
        ops.value,
        ops.unit,
    });
}

fn benchmark(
    name: []const u8,
    warmup_iterations: u64,
    iterations: u64,
    context: anytype,
    comptime func: fn (@TypeOf(context)) void,
) BenchmarkResult {
    // Warmup
    for (0..warmup_iterations) |_| {
        func(context);
    }

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    var timer = std.time.Timer.start() catch unreachable;

    for (0..iterations) |_| {
        timer.reset();
        func(context);
        const elapsed = timer.read();

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const avg_ns = total_ns / iterations;
    const ops_per_sec = if (avg_ns > 0) 1_000_000_000 / avg_ns else 0;

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .ops_per_sec = ops_per_sec,
    };
}

// ============================================================================
// Benchmark Functions
// ============================================================================

const BenchContext = struct {
    allocator: Allocator,
    container: *di.Container,
    scope: ?*di.Scope,
};

fn benchContainerInit(ctx: BenchContext) void {
    var container = di.Container.init(ctx.allocator);
    container.deinit();
}

fn benchRegisterSimple(ctx: BenchContext) void {
    ctx.container.register(SimpleService, .singleton) catch unreachable;
    // Reset for next iteration (remove the entry)
    _ = ctx.container.services.remove(@typeName(SimpleService));
}

fn benchResolveSingleton(ctx: BenchContext) void {
    const service = ctx.container.resolve(SimpleService) catch unreachable;
    std.mem.doNotOptimizeAway(service);
}

fn benchResolveTransient(ctx: BenchContext) void {
    const service = ctx.container.resolve(ServiceWithDeinit) catch unreachable;
    std.mem.doNotOptimizeAway(service);
    ctx.container.destroy(ServiceWithDeinit, service);
}

fn benchResolveWithInjected(ctx: BenchContext) void {
    const service = ctx.container.resolve(ServiceWithInjected) catch unreachable;
    std.mem.doNotOptimizeAway(service);
    ctx.container.destroy(ServiceWithInjected, service);
}

fn benchResolveWithLazy(ctx: BenchContext) void {
    const service = ctx.container.resolve(ServiceWithLazy) catch unreachable;
    std.mem.doNotOptimizeAway(service);
    ctx.container.destroy(ServiceWithLazy, service);
}

fn benchResolveLazyGet(ctx: BenchContext) void {
    const service = ctx.container.resolve(ServiceWithLazy) catch unreachable;
    const dep_a = service.dep_a.get() catch unreachable;
    const dep_b = service.dep_b.get() catch unreachable;
    std.mem.doNotOptimizeAway(dep_a);
    std.mem.doNotOptimizeAway(dep_b);
    ctx.container.destroy(ServiceWithLazy, service);
}

fn benchResolveDeepChain(ctx: BenchContext) void {
    const service = ctx.container.resolve(DeepDependencyChain) catch unreachable;
    std.mem.doNotOptimizeAway(service);
    ctx.container.destroy(DeepDependencyChain, service);
}

fn benchResolveComplex(ctx: BenchContext) void {
    const service = ctx.container.resolve(ComplexService) catch unreachable;
    std.mem.doNotOptimizeAway(service);
    ctx.container.destroy(ComplexService, service);
}

fn benchScopeCreateDestroy(ctx: BenchContext) void {
    var scope = ctx.container.createScope();
    scope.deinit();
}

fn benchNamedResolve(ctx: BenchContext) void {
    const service = ctx.container.resolveNamed(SimpleService, "named_service") catch unreachable;
    std.mem.doNotOptimizeAway(service);
}

fn benchFactoryResolve(ctx: BenchContext) void {
    const service = ctx.container.resolveNamed(SimpleService, "factory_service") catch unreachable;
    std.mem.doNotOptimizeAway(service);
    ctx.container.destroyNamed(SimpleService, "factory_service", service);
}

// Scoped benchmark context
const ScopedBenchContext = struct {
    scope: *di.Scope,

    fn benchScopedResolveCached(self: @This()) void {
        const service = self.scope.resolveNamed(SimpleService, "scoped_simple") catch unreachable;
        std.mem.doNotOptimizeAway(service);
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                        Zig DI Library Benchmark Suite                            ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const warmup: u64 = 1000;
    const iterations: u64 = 10000;

    // Setup container for benchmarks
    var container = di.Container.init(allocator);
    defer container.deinit();

    // Register services for resolution benchmarks
    try container.register(SimpleService, .singleton);
    try container.register(ServiceWithDeinit, .transient);
    try container.register(DependencyA, .singleton);
    try container.register(DependencyB, .singleton);
    try container.register(DependencyC, .singleton);
    try container.register(ServiceWithInjected, .transient);
    try container.register(ServiceWithLazy, .transient);
    try container.register(ServiceWithMixedDeps, .transient);
    try container.register(DeepDependencyChain, .transient);
    try container.register(ComplexService, .transient);

    // Named registration
    try container.registerNamed(SimpleService, "named_service", .singleton);

    // Factory registration
    try container.registerFactoryNamed(SimpleService, "factory_service", .transient, struct {
        fn create(c: *di.Container) !*SimpleService {
            const svc = try c.allocator.create(SimpleService);
            svc.* = .{ .value = 999 };
            return svc;
        }
    }.create);

    // Scoped registrations
    try container.registerNamed(SimpleService, "scoped_simple", .scoped);
    try container.registerNamed(ServiceWithInjected, "scoped_injected", .scoped);
    try container.registerNamed(DependencyA, "scoped_dep_a", .scoped);
    try container.registerNamed(DependencyB, "scoped_dep_b", .scoped);

    var ctx = BenchContext{
        .allocator = allocator,
        .container = &container,
        .scope = null,
    };

    // ========================================================================
    // Container Benchmarks
    // ========================================================================
    std.debug.print("Container Operations\n", .{});
    std.debug.print("──────────────────────────────────────────────────────────────────────────────────────\n", .{});

    printResult(benchmark("Container init + deinit", warmup, iterations, ctx, benchContainerInit));
    printResult(benchmark("Register simple service", warmup, iterations, ctx, benchRegisterSimple));

    // ========================================================================
    // Resolution Benchmarks
    // ========================================================================
    std.debug.print("\nResolution (from Container)\n", .{});
    std.debug.print("──────────────────────────────────────────────────────────────────────────────────────\n", .{});

    printResult(benchmark("Resolve singleton (cached)", warmup, iterations, ctx, benchResolveSingleton));
    printResult(benchmark("Resolve transient (new instance)", warmup, iterations, ctx, benchResolveTransient));
    printResult(benchmark("Resolve with 2x Injected deps", warmup, iterations, ctx, benchResolveWithInjected));
    printResult(benchmark("Resolve with 2x Lazy deps (no get)", warmup, iterations, ctx, benchResolveWithLazy));
    printResult(benchmark("Resolve with 2x Lazy deps + get()", warmup, iterations, ctx, benchResolveLazyGet));
    printResult(benchmark("Resolve deep chain (2 levels)", warmup, iterations, ctx, benchResolveDeepChain));
    printResult(benchmark("Resolve complex (3 Injected + 1 Lazy)", warmup, iterations, ctx, benchResolveComplex));

    // ========================================================================
    // Named & Factory Benchmarks
    // ========================================================================
    std.debug.print("\nNamed & Factory Resolution\n", .{});
    std.debug.print("──────────────────────────────────────────────────────────────────────────────────────\n", .{});

    printResult(benchmark("Resolve named singleton", warmup, iterations, ctx, benchNamedResolve));
    printResult(benchmark("Resolve factory transient", warmup, iterations, ctx, benchFactoryResolve));

    // ========================================================================
    // Scope Benchmarks
    // ========================================================================
    std.debug.print("\nScope Operations\n", .{});
    std.debug.print("──────────────────────────────────────────────────────────────────────────────────────\n", .{});

    printResult(benchmark("Scope create + destroy (empty)", warmup, iterations, ctx, benchScopeCreateDestroy));

    // Create a scope for scoped resolution benchmarks
    var scope = container.createScope();
    defer scope.deinit();
    ctx.scope = &scope;

    // Pre-resolve to cache scoped instances
    _ = try scope.resolveNamed(SimpleService, "scoped_simple");
    _ = try scope.resolveNamed(DependencyA, "scoped_dep_a");
    _ = try scope.resolveNamed(DependencyB, "scoped_dep_b");

    const scoped_ctx = ScopedBenchContext{ .scope = &scope };

    printResult(benchmark("Resolve scoped (cached)", warmup, iterations, scoped_ctx, ScopedBenchContext.benchScopedResolveCached));

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Benchmark complete. Iterations per test: {d}, Warmup: {d}\n", .{ iterations, warmup });
    std.debug.print("════════════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
}

// Allow running as test
test "benchmark runs without error" {
    // Just verify it compiles and the benchmark infrastructure works
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var container = di.Container.init(allocator);
    defer container.deinit();

    try container.register(SimpleService, .singleton);

    const ctx = BenchContext{
        .allocator = allocator,
        .container = &container,
        .scope = null,
    };

    const result = benchmark("test", 1, 10, ctx, benchResolveSingleton);
    try std.testing.expect(result.iterations == 10);
    try std.testing.expect(result.avg_ns > 0);
}
