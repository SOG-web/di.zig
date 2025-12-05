# Zig DI - Examples

This document contains comprehensive examples for all features of the Zig Dependency Injection library.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Lifetime Examples](#lifetime-examples)
  - [Singleton](#singleton)
  - [Transient](#transient)
  - [Scoped](#scoped)
- [Injection Types](#injection-types)
  - [Injected (Eager)](#injected-eager)
  - [Lazy (Deferred)](#lazy-deferred)
- [Custom Factories](#custom-factories)
- [Instance Registration](#instance-registration)
- [Named Registrations](#named-registrations)
- [Scoped Services](#scoped-services)
  - [Basic Scoped Services](#basic-scoped-services)
  - [Scoped with Injected Dependencies](#scoped-with-injected-dependencies)
  - [Scoped with Lazy Dependencies](#scoped-with-lazy-dependencies)
  - [Scoped with Custom Factories](#scoped-with-custom-factories)
  - [Mixed Singleton and Scoped](#mixed-singleton-and-scoped)
- [Circular Dependencies](#circular-dependencies)
- [Real-World Patterns](#real-world-patterns)
  - [HTTP Request Handling](#http-request-handling)
  - [Repository Pattern](#repository-pattern)

---

## Basic Usage

```zig
const std = @import("std");
const di = @import("di");

const Logger = struct {
    prefix: []const u8 = "[LOG]",

    pub fn log(self: *Logger, msg: []const u8) void {
        std.debug.print("{s} {s}\n", .{ self.prefix, msg });
    }
};

const UserService = struct {
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

    var container = di.Container.init(allocator);
    defer container.deinit();

    try container.register(Logger, .singleton);
    try container.register(UserService, .transient);

    const user_service = try container.resolve(UserService);
    user_service.createUser("Alice");

    container.destroy(UserService, user_service);
}
```

---

## Lifetime Examples

### Singleton

One instance shared across all resolutions:

```zig
const SimpleService = struct {
    value: i32 = 42,
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(SimpleService, .singleton);

const service1 = try container.resolve(SimpleService);
const service2 = try container.resolve(SimpleService);

// Same instance
std.debug.assert(service1 == service2);
std.debug.assert(service1.value == 42);
```

### Transient

New instance created for each resolution:

```zig
const TransientService = struct {
    value: i32 = 0,
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(TransientService, .transient);

const service1 = try container.resolve(TransientService);
const service2 = try container.resolve(TransientService);

// Different instances
std.debug.assert(service1 != service2);

// Caller must clean up transient instances
container.destroy(TransientService, service1);
container.destroy(TransientService, service2);
```

### Scoped

One instance per scope:

```zig
const Counter = struct {
    value: u32 = 0,

    pub fn increment(self: *@This()) void {
        self.value += 1;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(Counter, .scoped);

// Scope 1
{
    var scope = container.createScope();
    defer scope.deinit();

    const counter1 = try scope.resolve(Counter);
    counter1.increment();

    const counter2 = try scope.resolve(Counter);
    // Same instance within scope
    std.debug.assert(counter1 == counter2);
    std.debug.assert(counter2.value == 1);
}

// Scope 2 - fresh instance
{
    var scope = container.createScope();
    defer scope.deinit();

    const counter = try scope.resolve(Counter);
    std.debug.assert(counter.value == 0); // Fresh instance
}
```

---

## Injection Types

### Injected (Eager)

Dependencies resolved immediately when parent is created:

```zig
const Logger = struct {
    prefix: []const u8 = "[LOG]",
};

const UserService = struct {
    logger: di.Injected(Logger),
    name: []const u8 = "UserService",
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(Logger, .singleton);
try container.register(UserService, .singleton);

const service = try container.resolve(UserService);

std.debug.assert(std.mem.eql(u8, service.logger.get().prefix, "[LOG]"));
std.debug.assert(std.mem.eql(u8, service.name, "UserService"));
```

### Lazy (Deferred)

Dependencies resolved on first access:

```zig
const LazyDep = struct {
    initialized: bool = true,
};

const ServiceWithLazy = struct {
    lazy_dep: di.Lazy(LazyDep),
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(LazyDep, .singleton);
try container.register(ServiceWithLazy, .singleton);

const service = try container.resolve(ServiceWithLazy);

// LazyDep is NOT created yet

// Now it's created on first get()
const dep = try service.lazy_dep.get();
std.debug.assert(dep.initialized);
```

---

## Custom Factories

Use `registerFactory` for complex initialization:

```zig
const Database = struct {
    connection_string: []const u8,

    pub fn deinit(self: *@This()) void {
        // Cleanup resources
        _ = self;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.registerFactory(Database, .singleton, struct {
    fn create(c: *di.Container) !*Database {
        const db = try c.allocator.create(Database);
        db.* = .{
            .connection_string = "postgresql://localhost/test",
        };
        return db;
    }
}.create);

const db = try container.resolve(Database);
std.debug.assert(std.mem.eql(u8, db.connection_string, "postgresql://localhost/test"));
```

### Custom Factory with Injected Dependencies

Injected fields are still automatically wired even with custom factories:

```zig
const Logger = struct {
    prefix: []const u8 = "[LOG]",
};

const ServiceWithDeps = struct {
    logger: di.Injected(Logger),  // Will be auto-injected
    custom_value: u32,            // Set by factory

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(Logger, .singleton);
try container.registerFactory(ServiceWithDeps, .singleton, struct {
    fn create(c: *di.Container) !*ServiceWithDeps {
        const svc = try c.allocator.create(ServiceWithDeps);
        svc.* = .{
            .logger = undefined,  // Will be injected by container
            .custom_value = 42,
        };
        return svc;
    }
}.create);

const service = try container.resolve(ServiceWithDeps);

// Custom factory value is set
std.debug.assert(service.custom_value == 42);

// Injected dependency is also set
std.debug.assert(std.mem.eql(u8, service.logger.get().prefix, "[LOG]"));
```

---

## Instance Registration

Register pre-existing instances:

```zig
const Config = struct {
    port: u16,
    host: []const u8,
};

var container = di.Container.init(allocator);
defer container.deinit();

var config = Config{
    .port = 8080,
    .host = "localhost",
};

try container.registerInstance(Config, &config);

const resolved = try container.resolve(Config);
std.debug.assert(resolved.port == 8080);
std.debug.assert(resolved == &config);  // Same pointer
```

---

## Named Registrations

Register the same type with different lifetimes:

```zig
const MyService = struct {
    value: u32 = 0,
};

var container = di.Container.init(allocator);
defer container.deinit();

// Register same type with different lifetimes under different names
try container.registerNamed(MyService, "singleton_svc", .singleton);
try container.registerNamed(MyService, "transient_svc", .transient);
try container.registerNamed(MyService, "scoped_svc", .scoped);

// Resolve singleton - same instance
const s1 = try container.resolveNamed(MyService, "singleton_svc");
s1.value = 100;
const s2 = try container.resolveNamed(MyService, "singleton_svc");
std.debug.assert(s1 == s2);
std.debug.assert(s2.value == 100);

// Resolve transient - different instances
const t1 = try container.resolveNamed(MyService, "transient_svc");
const t2 = try container.resolveNamed(MyService, "transient_svc");
std.debug.assert(t1 != t2);

// Cleanup transients with name
container.destroyNamed(MyService, "transient_svc", t1);
container.destroyNamed(MyService, "transient_svc", t2);

// Resolve scoped through a scope
var scope = container.createScope();
defer scope.deinit();

const scoped1 = try scope.resolveNamed(MyService, "scoped_svc");
const scoped2 = try scope.resolveNamed(MyService, "scoped_svc");
std.debug.assert(scoped1 == scoped2);  // Same within scope
```

---

## Scoped Services

### Basic Scoped Services

```zig
const Counter = struct {
    value: u32 = 0,

    pub fn increment(self: *@This()) void {
        self.value += 1;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(Counter, .scoped);

var scope = container.createScope();
defer scope.deinit();

const counter1 = try scope.resolve(Counter);
counter1.increment();

const counter2 = try scope.resolve(Counter);

// Same instance within scope
std.debug.assert(counter1 == counter2);
std.debug.assert(counter2.value == 1);
```

### Scoped with Injected Dependencies

```zig
const RequestContext = struct {
    request_id: u64 = 12345,
};

const UserService = struct {
    ctx: di.Injected(RequestContext),
    name: []const u8 = "UserService",
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(RequestContext, .scoped);
try container.register(UserService, .scoped);

var scope = container.createScope();
defer scope.deinit();

const user_service = try scope.resolve(UserService);

std.debug.assert(user_service.ctx.get().request_id == 12345);

// The injected RequestContext is the same as directly resolved
const direct_ctx = try scope.resolve(RequestContext);
std.debug.assert(user_service.ctx.get() == direct_ctx);
```

### Scoped with Lazy Dependencies

```zig
const ScopedDep = struct {
    id: u64 = 42,
};

const ServiceWithLazy = struct {
    lazy_dep: di.Lazy(ScopedDep),
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(ScopedDep, .scoped);
try container.register(ServiceWithLazy, .scoped);

var scope = container.createScope();
defer scope.deinit();

const service = try scope.resolve(ServiceWithLazy);

// Lazy resolution goes through the scope, not container
const dep1 = try service.lazy_dep.get();
const dep2 = try service.lazy_dep.get();

// Same scoped instance
std.debug.assert(dep1 == dep2);
std.debug.assert(dep1.id == 42);

// Direct resolution also returns the same instance
const direct_dep = try scope.resolve(ScopedDep);
std.debug.assert(dep1 == direct_dep);
```

### Scoped with Custom Factories

#### Lazy Dependencies with Factories

```zig
const Database = struct {
    connection_id: u64,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

const Repository = struct {
    db: di.Lazy(Database),
    name: []const u8,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn getConnectionId(self: *@This()) !u64 {
        const db = try self.db.get();
        return db.connection_id;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

// Database with custom factory
try container.registerFactory(Database, .scoped, struct {
    fn create(c: *di.Container) !*Database {
        const db = try c.allocator.create(Database);
        db.* = .{
            .connection_id = 12345,
        };
        return db;
    }
}.create);

// Repository with custom factory
try container.registerFactory(Repository, .scoped, struct {
    fn create(c: *di.Container) !*Repository {
        const repo = try c.allocator.create(Repository);
        repo.* = .{
            .db = undefined,  // Will be injected
            .name = "UserRepository",
        };
        return repo;
    }
}.create);

var scope = container.createScope();
defer scope.deinit();

const repo = try scope.resolve(Repository);

// Custom factory values work
std.debug.assert(std.mem.eql(u8, repo.name, "UserRepository"));

// Lazy resolution works with scoped factory service
const conn_id = try repo.getConnectionId();
std.debug.assert(conn_id == 12345);

// Same scoped instance
const db1 = try repo.db.get();
const db2 = try repo.db.get();
std.debug.assert(db1 == db2);
```

#### Injected Dependencies with Factories

```zig
const RequestContext = struct {
    request_id: u64,
    user_agent: []const u8,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

const Logger = struct {
    prefix: []const u8,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

const UserService = struct {
    ctx: di.Injected(RequestContext),
    logger: di.Injected(Logger),
    service_name: []const u8,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn getRequestId(self: *@This()) u64 {
        return self.ctx.get().request_id;
    }

    pub fn getLoggerPrefix(self: *@This()) []const u8 {
        return self.logger.get().prefix;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.registerFactory(RequestContext, .scoped, struct {
    fn create(c: *di.Container) !*RequestContext {
        const ctx = try c.allocator.create(RequestContext);
        ctx.* = .{
            .request_id = 99999,
            .user_agent = "TestAgent/1.0",
        };
        return ctx;
    }
}.create);

try container.registerFactory(Logger, .scoped, struct {
    fn create(c: *di.Container) !*Logger {
        const logger = try c.allocator.create(Logger);
        logger.* = .{
            .prefix = "[REQUEST]",
        };
        return logger;
    }
}.create);

try container.registerFactory(UserService, .scoped, struct {
    fn create(c: *di.Container) !*UserService {
        const svc = try c.allocator.create(UserService);
        svc.* = .{
            .ctx = undefined,     // Will be injected
            .logger = undefined,  // Will be injected
            .service_name = "UserService",
        };
        return svc;
    }
}.create);

// Scope 1
{
    var scope = container.createScope();
    defer scope.deinit();

    const user_service = try scope.resolve(UserService);

    // Custom factory value
    std.debug.assert(std.mem.eql(u8, user_service.service_name, "UserService"));

    // Injected dependencies work
    std.debug.assert(user_service.getRequestId() == 99999);
    std.debug.assert(std.mem.eql(u8, user_service.getLoggerPrefix(), "[REQUEST]"));

    // Scoped instances are shared
    const direct_ctx = try scope.resolve(RequestContext);
    std.debug.assert(user_service.ctx.get() == direct_ctx);
}

// Scope 2 - fresh instances
{
    var scope2 = container.createScope();
    defer scope2.deinit();

    const user_service = try scope2.resolve(UserService);
    std.debug.assert(user_service.getRequestId() == 99999);  // Same value, different instance
}
```

### Mixed Singleton and Scoped

```zig
const GlobalConfig = struct {
    app_name: []const u8,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

const RequestHandler = struct {
    config: di.Lazy(GlobalConfig),
    request_id: u64,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn getAppName(self: *@This()) ![]const u8 {
        const cfg = try self.config.get();
        return cfg.app_name;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

// Singleton
try container.registerFactory(GlobalConfig, .singleton, struct {
    fn create(c: *di.Container) !*GlobalConfig {
        const cfg = try c.allocator.create(GlobalConfig);
        cfg.* = .{
            .app_name = "MyApp",
        };
        return cfg;
    }
}.create);

// Scoped
try container.registerFactory(RequestHandler, .scoped, struct {
    fn create(c: *di.Container) !*RequestHandler {
        const handler = try c.allocator.create(RequestHandler);
        handler.* = .{
            .config = undefined,  // Will be injected
            .request_id = 42,
        };
        return handler;
    }
}.create);

var scope1 = container.createScope();
defer scope1.deinit();

var scope2 = container.createScope();
defer scope2.deinit();

const handler1 = try scope1.resolve(RequestHandler);
const handler2 = try scope2.resolve(RequestHandler);

// Handlers are different (scoped)
std.debug.assert(handler1 != handler2);

// But they share the same singleton config
const config1 = try handler1.config.get();
const config2 = try handler2.config.get();
std.debug.assert(config1 == config2);

const app_name1 = try handler1.getAppName();
const app_name2 = try handler2.getAppName();
std.debug.assert(std.mem.eql(u8, app_name1, "MyApp"));
std.debug.assert(std.mem.eql(u8, app_name2, "MyApp"));
```

---

## Circular Dependencies

Break circular dependencies using `Lazy`:

```zig
// ❌ WILL CAUSE STACK OVERFLOW
// const ServiceA = struct {
//     b: di.Injected(ServiceB),
// };
// const ServiceB = struct {
//     a: di.Injected(ServiceA),
// };

// ✅ USE Lazy TO BREAK THE CYCLE
const ServiceA = struct {
    b: di.Injected(ServiceB),
};

const ServiceB = struct {
    a: di.Lazy(ServiceA),  // Lazy breaks the cycle
    
    pub fn doSomething(self: *ServiceB) !void {
        const a = try self.a.get();  // Resolved here, after construction
        _ = a;
    }
};

var container = di.Container.init(allocator);
defer container.deinit();

try container.register(ServiceA, .singleton);
try container.register(ServiceB, .singleton);

const service_b = try container.resolve(ServiceB);
try service_b.doSomething();
```

---

## Real-World Patterns

### HTTP Request Handling

```zig
const RequestContext = struct {
    request_id: u64,
    user_id: ?u64,
    path: []const u8,
};

const DatabaseConnection = struct {
    id: u64,
    
    pub fn deinit(self: *@This()) void {
        // Close connection
        _ = self;
    }
};

const UserRepository = struct {
    db: di.Injected(DatabaseConnection),
    ctx: di.Injected(RequestContext),
    
    pub fn getCurrentUser(self: *@This()) !?User {
        const user_id = self.ctx.get().user_id orelse return null;
        // Use self.db.get() to query
        _ = user_id;
        return null;
    }
};

const AuthService = struct {
    user_repo: di.Lazy(UserRepository),
    ctx: di.Injected(RequestContext),
};

// Setup (at application startup)
fn setupContainer(allocator: std.mem.Allocator) !di.Container {
    var container = di.Container.init(allocator);
    
    try container.registerFactory(DatabaseConnection, .scoped, struct {
        fn create(c: *di.Container) !*DatabaseConnection {
            const conn = try c.allocator.create(DatabaseConnection);
            conn.* = .{ .id = generateConnectionId() };
            return conn;
        }
    }.create);
    
    try container.register(RequestContext, .scoped);
    try container.register(UserRepository, .scoped);
    try container.register(AuthService, .scoped);
    
    return container;
}

// Per-request handler
fn handleRequest(container: *di.Container, raw_request: RawRequest) !Response {
    var scope = container.createScope();
    defer scope.deinit();  // All scoped instances cleaned up here
    
    // Initialize request context
    const ctx = try scope.resolve(RequestContext);
    ctx.* = .{
        .request_id = raw_request.id,
        .user_id = raw_request.authenticated_user,
        .path = raw_request.path,
    };
    
    // Use services
    const auth = try scope.resolve(AuthService);
    // ... handle request
    
    return Response{};
}
```

### Repository Pattern

```zig
const Entity = struct {
    id: u64,
    name: []const u8,
};

const DbContext = struct {
    transaction_id: u64,
    
    pub fn deinit(self: *@This()) void {
        // Commit/rollback transaction
        _ = self;
    }
};

const GenericRepository = struct {
    db: di.Injected(DbContext),
    
    pub fn findById(self: *@This(), id: u64) !?Entity {
        _ = self;
        _ = id;
        return null;
    }
    
    pub fn save(self: *@This(), entity: Entity) !void {
        _ = self;
        _ = entity;
    }
};

const UnitOfWork = struct {
    db: di.Injected(DbContext),
    users: di.Lazy(GenericRepository),
    orders: di.Lazy(GenericRepository),
    
    pub fn commit(self: *@This()) !void {
        // Commit the shared DbContext
        _ = self;
    }
};

// All repositories in a unit of work share the same DbContext
var container = di.Container.init(allocator);
defer container.deinit();

try container.register(DbContext, .scoped);
try container.register(GenericRepository, .scoped);
try container.register(UnitOfWork, .scoped);

{
    var scope = container.createScope();
    defer scope.deinit();
    
    const uow = try scope.resolve(UnitOfWork);
    
    // users and orders share the same DbContext
    const users = try uow.users.get();
    const orders = try uow.orders.get();
    
    std.debug.assert(users.db.get() == orders.db.get());
    std.debug.assert(users.db.get() == uow.db.get());
    
    try uow.commit();
}
```

---

## Error Handling

```zig
const UnregisteredService = struct {};

var container = di.Container.init(allocator);
defer container.deinit();

// Attempting to resolve unregistered service
const result = container.resolve(UnregisteredService);

if (result) |_| {
    // Success
} else |err| switch (err) {
    error.ServiceNotRegistered => {
        std.debug.print("Service not registered!\n", .{});
    },
    error.ScopedNotImplemented => {
        std.debug.print("Cannot resolve scoped service from container directly\n", .{});
    },
    else => {
        std.debug.print("Other error: {}\n", .{err});
    },
}
```
