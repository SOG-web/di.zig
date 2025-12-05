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

## Services with Custom Initialization

When your service has custom initialization logic (like setting up caches, connection pools, or other resources), use `registerFactory` to register it as a singleton:

```zig
const AuthService = struct {
    allocator: std.mem.Allocator,
    db: di.Injected(pg.Pool),
    jwt: di.Injected(JwtService),
    config: di.Injected(Config),
    user_cache: Cache(AuthUser),

    pub fn init(allocator: std.mem.Allocator) !AuthService {
        // Initialize cache for auth users (5 minute TTL, max 2000 users)
        const user_cache = try Cache(AuthUser).init(allocator, .{
            .max_size = 2000,
            .segment_count = 8,
        });

        return AuthService{
            .allocator = allocator,
            .user_cache = user_cache,
        };
    }

    pub fn deinit(self: *AuthService) void {
        self.user_cache.deinit();
    }
};

// Register with a factory to handle custom initialization
try container.registerFactory(AuthService, .singleton, struct {
    fn create(c: *di.Container) !*AuthService {
        const auth_service = try c.allocator.create(AuthService);
        auth_service.* = try AuthService.init(c.allocator);
        return auth_service;
    }
}.create);

// Resolve and use - Injected fields (db, jwt, config) are automatically populated
const auth = try container.resolve(AuthService);
```

**Key points:**
- The factory calls your custom `init` function with any required parameters
- `Injected(T)` fields are automatically populated by the container after the factory returns
- The `deinit` method is called automatically when `container.deinit()` is invoked
- Use `.singleton` to ensure only one instance exists throughout your application

## Instance Registration

Register an externally-created instance. Any `Injected(T)` or `Lazy(T)` fields will be automatically populated:

```zig
const Logger = struct {
    prefix: []const u8 = "[LOG]",
};

const ServiceWithDeps = struct {
    logger: di.Injected(Logger),
    config: di.Lazy(Config),
    custom_value: u32,
};

// Register dependencies first
try container.register(Logger, .singleton);
try container.register(Config, .singleton);

// Create an instance externally with custom values
var service = ServiceWithDeps{
    .logger = undefined,     // Will be auto-injected
    .config = undefined,     // Will be auto-injected
    .custom_value = 42,      // Your custom initialization
};

try container.registerInstance(ServiceWithDeps, &service);

// Resolve and use - all dependencies are injected
const resolved = try container.resolve(ServiceWithDeps);
resolved.logger.get().log("Hello");  // Works!

// The container will NOT destroy this instance on deinit
// (since it doesn't own it)
```

**Key points:**
- `Injected(T)` and `Lazy(T)` fields are automatically populated when registering
- The container does NOT call `deinit` on externally-provided instances
- The instance pointer must remain valid for the lifetime of the container

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

### `init` - Post-Injection Initialization

Called after the instance is created and all dependencies are injected. The container supports multiple `init` signatures, including error-returning and factory-style variants.

#### Supported Signatures

##### `fn init() void` - Static initialization

```zig
const MetricsService = struct {
    var instance_count: u32 = 0;
    value: u32 = 0,

    pub fn init() void {
        instance_count += 1; // Track total instances created
    }
};
```

##### `fn init() !void` - Static initialization that can fail

```zig
const ConfigLoader = struct {
    var config_loaded: bool = false;
    data: []const u8 = "",

    pub fn init() !void {
        if (config_loaded) return;
        // Could fail during static setup
        config_loaded = true;
    }
};
```

##### `fn init() T` - Factory returning new instance

```zig
const SimpleFactory = struct {
    value: u32,
    name: []const u8,

    pub fn init() @This() {
        return .{
            .value = 42,
            .name = "factory-created",
        };
    }
};
```

##### `fn init() !T` - Factory returning new instance, can fail

```zig
const ValidatedService = struct {
    config_valid: bool,

    pub fn init() !@This() {
        // Validation logic that might fail
        if (!checkEnvironment()) return error.InvalidEnvironment;
        return .{ .config_valid = true };
    }
};
```

##### `fn init(self: *T) void` - In-place initialization

```zig
const Counter = struct {
    config: di.Injected(Config),
    count: u32 = 0,

    pub fn init(self: *@This()) void {
        // Dependencies are available here
        self.count = self.config.get().initial_count;
    }
};
```

##### `fn init(self: *T) !void` - In-place initialization that can fail

```zig
const ConnectionPool = struct {
    logger: di.Injected(Logger),
    connections: u32 = 0,

    pub fn init(self: *@This()) !void {
        self.logger.get().log("Initializing pool...");
        self.connections = try self.createConnections();
    }
};
```

##### `fn init(allocator) void` - Static initialization with allocator

```zig
const SharedPool = struct {
    var global_pool: ?*Pool = null;

    pub fn init(allocator: std.mem.Allocator) void {
        if (global_pool == null) {
            global_pool = allocator.create(Pool) catch null;
        }
    }
};
```

##### `fn init(allocator) !void` - Static initialization with allocator, can fail

```zig
const GlobalCache = struct {
    var shared_buffer: ?[]u8 = null;

    pub fn init(allocator: std.mem.Allocator) !void {
        if (shared_buffer == null) {
            shared_buffer = try allocator.alloc(u8, 4096);
        }
    }
};
```

##### `fn init(allocator) T` - Factory with allocator

```zig
const BufferService = struct {
    buffer: []u8,
    allocator_ref: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .buffer = allocator.alloc(u8, 1024) catch &[_]u8{},
            .allocator_ref = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.buffer.len > 0) self.allocator_ref.free(self.buffer);
    }
};
```

##### `fn init(allocator) !T` - Factory with allocator, can fail (Most Common Factory Style)

```zig
const AuthService = struct {
    allocator: std.mem.Allocator,
    db: di.Injected(Database),      // Injected AFTER init returns
    user_cache: Cache(AuthUser),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const user_cache = try Cache(AuthUser).init(allocator, .{
            .max_size = 2000,
        });
        return .{
            .allocator = allocator,
            .db = undefined,  // Will be injected
            .user_cache = user_cache,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.user_cache.deinit();
    }
};
```

##### `fn init(self: *T, allocator) void` - Full in-place initialization

```zig
const DataProcessor = struct {
    logger: di.Injected(Logger),
    buffer: ?[]u8 = null,
    allocator_ref: ?std.mem.Allocator = null,

    pub fn init(self: *@This(), allocator: std.mem.Allocator) void {
        self.allocator_ref = allocator;
        self.buffer = allocator.alloc(u8, 512) catch null;
        // Dependencies available
        self.logger.get().log("DataProcessor ready");
    }

    pub fn deinit(self: *@This()) void {
        if (self.buffer) |b| {
            if (self.allocator_ref) |a| a.free(b);
        }
    }
};
```

##### `fn init(self: *T, allocator) !void` - Full in-place initialization, can fail

```zig
const SecureService = struct {
    config: di.Injected(Config),
    keys: ?[]u8 = null,
    allocator_ref: ?std.mem.Allocator = null,

    pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
        self.allocator_ref = allocator;
        // Dependencies are available
        const key_size = self.config.get().key_size;
        self.keys = try allocator.alloc(u8, key_size);
        try self.loadKeys();
    }

    pub fn deinit(self: *@This()) void {
        if (self.keys) |k| {
            if (self.allocator_ref) |a| a.free(k);
        }
    }
};
```

#### Summary Table

| Signature | Style | Dependencies Available In `init` |
|-----------|-------|----------------------------------|
| `fn init() void` | Static | No |
| `fn init() !void` | Static | No |
| `fn init() T` | Factory | No (injected after) |
| `fn init() !T` | Factory | No (injected after) |
| `fn init(self: *T) void` | In-place | Yes |
| `fn init(self: *T) !void` | In-place | Yes |
| `fn init(allocator) void` | Static | No |
| `fn init(allocator) !void` | Static | No |
| `fn init(allocator) T` | Factory | No (injected after) |
| `fn init(allocator) !T` | Factory | No (injected after) |
| `fn init(self: *T, allocator) void` | In-place | Yes |
| `fn init(self: *T, allocator) !void` | In-place | Yes |

#### In-place Initialization (Most Common)

Modify the instance after dependencies are injected. Dependencies are available inside `init`:

```zig
const Cache = struct {
    config: di.Injected(Config),
    data: ?std.StringHashMap([]const u8) = null,

    pub fn init(self: *Cache) !void {
        // Dependencies are available here
        const size = self.config.get().cache_size;
        self.data = try self.initHashMap(size);
    }
};
```

#### Factory-style Initialization

For services with complex construction, `init` can return a new instance. Dependencies are injected **after** the factory returns:

```zig
const AuthService = struct {
    allocator: std.mem.Allocator,
    db: di.Injected(Database),      // Injected AFTER init returns
    jwt: di.Injected(JwtService),   // Injected AFTER init returns
    user_cache: Cache(AuthUser),

    pub fn init(allocator: std.mem.Allocator) !AuthService {
        // Create cache and other resources
        const user_cache = try Cache(AuthUser).init(allocator, .{
            .max_size = 2000,
            .segment_count = 8,
        });

        return AuthService{
            .allocator = allocator,
            .db = undefined,         // Will be injected
            .jwt = undefined,        // Will be injected
            .user_cache = user_cache,
        };
    }

    pub fn deinit(self: *AuthService) void {
        self.user_cache.deinit();
    }
};

// Just register normally - no need for registerFactory!
try container.register(AuthService, .singleton);
```

#### Error Handling

Errors from `init` propagate to the caller of `resolve`:

```zig
const DatabaseService = struct {
    connection: *Connection,

    pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
        self.connection = try Connection.open(allocator, "db://localhost");
    }
};

// Error propagates from init
const db = container.resolve(DatabaseService) catch |err| {
    std.log.err("Failed to initialize database: {}", .{err});
    return err;
};
```

#### Full Initialization with Allocator

For services that need both instance access and allocator:

```zig
const BufferedService = struct {
    logger: di.Injected(Logger),
    buffer: ?[]u8 = null,
    allocator_ref: ?std.mem.Allocator = null,

    pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
        self.allocator_ref = allocator;
        self.buffer = try allocator.alloc(u8, 1024);
        // Injected dependencies are available
        self.logger.get().log("BufferedService initialized");
    }

    pub fn deinit(self: *@This()) void {
        if (self.buffer) |b| {
            if (self.allocator_ref) |alloc| {
                alloc.free(b);
            }
        }
    }
};
```

**Key Points:**
- **In-place init** (`self: *T`): Dependencies are injected **before** `init` is called, so they're accessible inside `init`
- **Factory-style init** (returns `T`): Dependencies are injected **after** `init` returns
- **Static init** (no `self`): No instance access, useful for global/shared state setup
- Error-returning variants (`!void`, `!T`) propagate errors to the `resolve` caller

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
