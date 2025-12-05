# Zig Dependency Injection

A compile-time safe dependency injection container for Zig, supporting constructor injection, field injection, and multiple service lifetimes.

> 📚 **[See EXAMPLES.md for comprehensive usage examples](EXAMPLES.md)**

## Features

- **Type-safe**: Leverages Zig's comptime capabilities for compile-time type checking
- **Three Lifetime Scopes**: Singleton, Transient, and Scoped
- **Field Injection**: Automatic injection via `Injected(T)` and `Lazy(T)` wrapper types
- **Custom Factories**: Register services with custom creation logic
- **Instance Registration**: Register pre-existing instances as singletons
- **Thread-safe Singletons**: Double-checked locking for safe concurrent access
- **Scoped Contexts**: Perfect for HTTP requests, background jobs, or unit-of-work patterns

## Installation

Add this package to your `build.zig.zon`:

```zon
.dependencies = .{
    .di = .{
        .url = "https://github.com/SOG-web/di.zig#main",
        .hash = "...", // Update with actual hash
    },
},
```

Then in your `build.zig`:

```zig
const di = b.dependency("di", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("di", di.module("di"));
```

## Quick Start

```zig
const std = @import("std");
const di = @import("di");

// Define your services
const Logger = struct {
    prefix: []const u8 = "[LOG]",

    pub fn log(self: *Logger, msg: []const u8) void {
        std.debug.print("{s} {s}\n", .{ self.prefix, msg });
    }
};

const UserService = struct {
    // Automatically injected when UserService is resolved
    logger: di.Injected(Logger),

    pub fn createUser(self: *UserService, name: []const u8) void {
        self.logger.get().log("Creating user");
        _ = name;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create and configure the container
    var container = di.Container.init(allocator);
    defer container.deinit();

    try container.register(Logger, .singleton);
    try container.register(UserService, .transient);

    // Resolve and use services
    const user_service = try container.resolve(UserService);
    user_service.createUser("Alice");

    // Clean up transient instances manually
    container.destroy(UserService, user_service);
}
```

## Lifetimes

### Singleton

One instance is created and shared across all resolutions for the lifetime of the container.

```zig
try container.register(Config, .singleton);

const config1 = try container.resolve(Config);
const config2 = try container.resolve(Config);
// config1 == config2 (same instance)
```

**Use for**: Configuration, logging, caches, connection pools.

### Transient

A new instance is created every time the service is resolved. The caller is responsible for cleanup.

```zig
try container.register(RequestHandler, .transient);

const handler1 = try container.resolve(RequestHandler);
const handler2 = try container.resolve(RequestHandler);
// handler1 != handler2 (different instances)

// Caller must clean up
container.destroy(RequestHandler, handler1);
container.destroy(RequestHandler, handler2);
```

**Use for**: Stateless services, lightweight objects, services with per-use state.

### Scoped

One instance per scope. Instances are automatically destroyed when the scope ends.

```zig
try container.register(DbConnection, .scoped);
try container.register(UserRepository, .scoped);

// Create a scope (e.g., for an HTTP request)
var scope = container.createScope();
defer scope.deinit(); // All scoped instances cleaned up here

const repo1 = try scope.resolve(UserRepository);
const repo2 = try scope.resolve(UserRepository);
// repo1 == repo2 (same instance within this scope)
```

**Use for**: Database connections per request, request context, unit-of-work pattern.

## Injection Types

### `Injected(T)` - Eager Injection

The dependency is resolved immediately when the parent service is created.

```zig
const OrderService = struct {
    db: di.Injected(Database),
    logger: di.Injected(Logger),

    pub fn placeOrder(self: *OrderService) void {
        self.logger.get().log("Placing order");
        self.db.get().execute("INSERT INTO orders ...");
    }
};
```

### `Lazy(T)` - Deferred Injection

The dependency is resolved only when first accessed via `get()`.

```zig
const ReportService = struct {
    // Heavy service, only created if actually needed
    analytics: di.Lazy(AnalyticsEngine),

    pub fn generateReport(self: *ReportService, include_analytics: bool) void {
        if (include_analytics) {
            // AnalyticsEngine is created here, on first access
            const engine = try self.analytics.get();
            engine.process();
        }
    }
};
```

## Custom Factories

For complex initialization logic, register a custom factory:

```zig
const Database = struct {
    connection_string: []const u8,
    pool_size: u32,

    pub fn deinit(self: *Database) void {
        // Close connections, cleanup resources
        _ = self;
    }
};

try container.registerFactory(Database, .singleton, struct {
    fn create(c: *di.Container) !*Database {
        const db = try c.allocator.create(Database);
        db.* = .{
            .connection_string = "postgresql://localhost/mydb",
            .pool_size = 10,
        };
        // Perform additional initialization...
        return db;
    }
}.create);
```

## Instance Registration

Register an externally-created instance:

```zig
var config = Config{
    .port = 8080,
    .host = "localhost",
};

try container.registerInstance(Config, &config);

// The container will NOT destroy this instance on deinit
// (since it doesn't own it)
```

## Scoped Services Deep Dive

Scopes are essential for request-based or job-based processing where you need isolated instances.

### HTTP Request Example

```zig
const RequestContext = struct {
    request_id: u64,
    user_id: ?u64 = null,
};

const UserRepository = struct {
    ctx: di.Injected(RequestContext),
    db: di.Injected(DbConnection),

    pub fn getCurrentUser(self: *UserRepository) !User {
        // Both ctx and db are shared within this request
        const user_id = self.ctx.get().user_id orelse return error.NotAuthenticated;
        return self.db.get().findUser(user_id);
    }
};

// Setup
try container.register(DbConnection, .scoped);
try container.register(RequestContext, .scoped);
try container.register(UserRepository, .scoped);
try container.register(GlobalConfig, .singleton);

// Handle request
fn handleRequest(container: *di.Container, raw_request: RawRequest) !Response {
    var scope = container.createScope();
    defer scope.deinit(); // DbConnection, RequestContext, UserRepository all cleaned up

    // Initialize request-specific data
    const ctx = try scope.resolve(RequestContext);
    ctx.request_id = raw_request.id;
    ctx.user_id = raw_request.authenticated_user;

    // Use services
    const repo = try scope.resolve(UserRepository);
    const user = try repo.getCurrentUser();

    return Response{ .user = user };
}
```

### Scoped vs Singleton Resolution

When resolving through a scope:

| Service Lifetime | Resolved From | Cached In |
|------------------|---------------|-----------|
| Singleton | Container | Container |
| Scoped | Scope | Scope |
| Transient | Created fresh | Not cached |

```zig
// Singletons are shared across ALL scopes
const logger1 = try scope1.resolve(Logger); // From container
const logger2 = try scope2.resolve(Logger); // Same instance

// Scoped services are isolated per scope
const ctx1 = try scope1.resolve(RequestContext); // Scope1's instance
const ctx2 = try scope2.resolve(RequestContext); // Different instance
```

## Service Requirements

Services can optionally implement:

### `deinit(self: *Self) void`

Called when the service is destroyed (scope end for scoped, container deinit for singletons).

```zig
const Connection = struct {
    handle: *c.pg_conn,

    pub fn deinit(self: *Connection) void {
        c.pg_close(self.handle);
    }
};
```

### `init(self: *Self) void`

Called after the instance is created and all dependencies are injected.

```zig
const Cache = struct {
    data: std.StringHashMap([]const u8),

    pub fn init(self: *Cache) void {
        // Additional initialization after DI
        self.warmup();
    }

    fn warmup(self: *Cache) void {
        // Pre-populate cache...
        _ = self;
    }
};
```

## Named Registrations

You can register the same type multiple times with different lifetimes using named registrations:

```zig
const MyService = struct {
    value: u32 = 0,
};

// Register the same type with different lifetimes
try container.registerNamed(MyService, "singleton_svc", .singleton);
try container.registerNamed(MyService, "scoped_svc", .scoped);
try container.registerNamed(MyService, "transient_svc", .transient);

// Resolve by name
const singleton = try container.resolveNamed(MyService, "singleton_svc");
const transient = try container.resolveNamed(MyService, "transient_svc");

// In a scope
var scope = container.createScope();
defer scope.deinit();

const scoped = try scope.resolveNamed(MyService, "scoped_svc");

// Clean up transient with name
container.destroyNamed(MyService, "transient_svc", transient);
```

### Use Cases for Named Registrations

1. **Different configurations**: Same service type with different settings
2. **Testing**: Register mock vs real implementations under different names
3. **Multi-tenancy**: Different service instances per tenant
4. **Feature flags**: Switch between implementations at runtime

## API Reference

### `Container`

| Method | Description |
|--------|-------------|
| `init(allocator) Container` | Create a new container |
| `deinit()` | Destroy container and all singleton instances |
| `register(T, lifetime)` | Register a type with automatic construction |
| `registerNamed(T, name, lifetime)` | Register a type with a custom name |
| `registerFactory(T, lifetime, factory)` | Register with custom factory function |
| `registerFactoryNamed(T, name, lifetime, factory)` | Register factory with custom name |
| `registerInstance(T, *T)` | Register an existing instance as singleton |
| `registerInstanceNamed(T, name, *T)` | Register instance with custom name |
| `resolve(T) !*T` | Resolve a service |
| `resolveNamed(T, name) !*T` | Resolve a service by name |
| `createScope() Scope` | Create a new scope for scoped services |
| `isRegistered(T) bool` | Check if a type is registered |
| `destroy(T, *T)` | Manually destroy a transient instance |
| `destroyNamed(T, name, *T)` | Destroy a named transient instance |

### `Scope`

| Method | Description |
|--------|-------------|
| `init(container) Scope` | Create scope from container |
| `deinit()` | Destroy scope and all scoped instances |
| `resolve(T) !*T` | Resolve a service (respects all lifetimes) |
| `resolveNamed(T, name) !*T` | Resolve a service by name |
| `destroy(T, *T)` | Manually destroy a transient instance |

### Wrapper Types

| Type | Description |
|------|-------------|
| `Injected(T)` | Eagerly injected dependency, access via `.get()` |
| `Lazy(T)` | Lazily injected dependency, access via `.get()` (returns error union). Works correctly in both Container and Scope contexts. |

### Resolver Interface

The `Resolver` type provides a unified interface for resolving dependencies from either a `Container` or a `Scope`. This is used internally by `Lazy(T)` to ensure lazy dependencies resolve correctly regardless of context.

```zig
// Get a resolver from a container
const resolver = container.resolver();

// Get a resolver from a scope
const resolver = scope.resolver();

// Resolve through the interface
const service = try resolver.resolve(MyService);
```

## Error Handling

| Error | Cause |
|-------|-------|
| `error.ServiceNotRegistered` | Attempted to resolve a type that wasn't registered |
| `error.ScopedNotImplemented` | Attempted to resolve scoped service directly from container (use a Scope) |

## Thread Safety

- **Singleton creation** is thread-safe (uses mutex with double-checked locking)
- **Scopes** are NOT thread-safe - each thread should have its own scope
- **Container registration** should be done before spawning threads

## Circular Dependencies

This library does **not** automatically detect circular dependencies at compile time or runtime. If you have circular dependencies with eager injection (`Injected(T)`), you will get a stack overflow or infinite loop.

### The Problem

```zig
// ❌ WILL CAUSE STACK OVERFLOW
const ServiceA = struct {
    b: di.Injected(ServiceB), // Resolves ServiceB, which resolves ServiceA, which resolves ServiceB...
};

const ServiceB = struct {
    a: di.Injected(ServiceA), // Circular!
};
```

### The Solution: Use `Lazy(T)`

Break the cycle by using `Lazy(T)` on at least one side of the circular dependency:

```zig
// ✅ WORKS - Lazy breaks the cycle
const ServiceA = struct {
    b: di.Injected(ServiceB),
};

const ServiceB = struct {
    a: di.Lazy(ServiceA), // Lazy injection - resolved on first .get() call, not during construction
    
    pub fn doSomething(self: *ServiceB) !void {
        const a = try self.a.get(); // ServiceA is resolved here, after ServiceB is fully constructed
        _ = a;
    }
};
```

### Why This Works

1. When `ServiceA` is resolved, it tries to inject `ServiceB`
2. `ServiceB` is created, but `Lazy(ServiceA)` just stores a reference to the container - it doesn't resolve `ServiceA` yet
3. `ServiceB` construction completes, `ServiceA` construction completes
4. Later, when `ServiceB.doSomething()` calls `self.a.get()`, `ServiceA` is already cached (singleton) or created fresh (transient)

### Best Practice

If you have circular dependencies, consider if your design could be improved. Circular dependencies often indicate:
- Services that should be merged
- A missing abstraction
- Responsibilities that should be reorganized

If circular dependencies are truly necessary, use `Lazy(T)` on the dependency that is accessed less frequently or later in the lifecycle.

## Best Practices

1. **Register all services at startup** before any resolution
2. **Use scopes for request/job boundaries** to ensure proper cleanup
3. **Prefer `Injected(T)` over `Lazy(T)`** unless you have a specific reason for lazy loading
4. **Don't inject scoped services into singletons** (captive dependency problem)
5. **Call `deinit()` on scopes** (use `defer`) to prevent resource leaks
6. **Use `Lazy(T)` to break circular dependencies** - at least one side must be lazy

## Benchmarks

Run benchmarks with:

```bash
zig build bench
```

<!--### Sample Results (Apple Intel)

| Operation | Avg Time | Ops/sec |
|-----------|----------|---------|
| Container init + deinit | 44 ns | 22.7M |
| Register simple service | 74 ns | 13.5M |
| Resolve singleton (cached) | 61 ns | 16.4M |
| Resolve transient (new instance) | 9.2 µs | 109K |
| Resolve with 2x Injected deps | 9.2 µs | 109K |
| Resolve with 2x Lazy deps (no get) | 9.1 µs | 110K |
| Resolve named singleton | 70 ns | 14.3M |
| Resolve factory transient | 124 ns | 8.1M |
| Scope create + destroy (empty) | 45 ns | 22.2M |
| Resolve scoped (cached) | 73 ns | 13.7M |-->

**Key Takeaways:**
- Cached resolutions (singleton, scoped) are very fast (~60-75 ns)
- Transient resolution involves memory allocation (~9 µs)
- Lazy dependencies add minimal overhead when not accessed
- Scope creation/destruction is lightweight (~45 ns)

## More Examples

For comprehensive examples covering all features, see **[EXAMPLES.md](EXAMPLES.md)**, which includes:

- All lifetime examples (singleton, transient, scoped)
- Injection types (Injected, Lazy)
- Custom factories with dependency injection
- Named registrations
- Scoped services with factories
- Mixed singleton and scoped patterns
- Real-world patterns (HTTP request handling, repository pattern)
- Circular dependency solutions

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
