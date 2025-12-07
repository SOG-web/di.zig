const std = @import("std");

const di = @import("root.zig");
const Container = di.Container;
const Injected = di.Injected;
const Lazy = di.Lazy;
const Scope = di.Scope;

test "basic singleton registration and resolution" {
    const allocator = std.testing.allocator;

    const SimpleService = struct {
        value: i32 = 42,
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(SimpleService, .singleton);

    const service1 = try container.resolve(SimpleService);
    const service2 = try container.resolve(SimpleService);

    // Should be the same instance
    try std.testing.expectEqual(service1, service2);
    try std.testing.expectEqual(@as(i32, 42), service1.value);
}

test "transient creates new instances" {
    const allocator = std.testing.allocator;

    const TransientService = struct {
        value: i32 = 0,
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(TransientService, .transient);

    const service1 = try container.resolve(TransientService);
    const service2 = try container.resolve(TransientService);

    // Should be different instances
    try std.testing.expect(service1 != service2);

    // Clean up transient instances
    container.destroy(TransientService, service1);
    container.destroy(TransientService, service2);
}

test "injected dependency" {
    const allocator = std.testing.allocator;

    const Logger = struct {
        prefix: []const u8 = "[LOG]",
    };

    const UserService = struct {
        logger: Injected(Logger),
        name: []const u8 = "UserService",
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(Logger, .singleton);
    try container.register(UserService, .singleton);

    const service = try container.resolve(UserService);

    try std.testing.expectEqualStrings("[LOG]", service.logger.get().prefix);
    try std.testing.expectEqualStrings("UserService", service.name);
}

test "lazy dependency" {
    const allocator = std.testing.allocator;

    const LazyDep = struct {
        initialized: bool = true,
    };

    const ServiceWithLazy = struct {
        lazy_dep: Lazy(LazyDep),
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(LazyDep, .singleton);
    try container.register(ServiceWithLazy, .singleton);

    const service = try container.resolve(ServiceWithLazy);

    // Lazy dependency is resolved on demand
    const dep = try service.lazy_dep.get();
    try std.testing.expect(dep.initialized);
}

test "unregistered service returns error" {
    const allocator = std.testing.allocator;

    const UnregisteredService = struct {};

    var container = Container.init(allocator);
    defer container.deinit();

    const result = container.resolve(UnregisteredService);
    try std.testing.expectError(error.ServiceNotRegistered, result);
}

test "register existing instance" {
    const allocator = std.testing.allocator;

    const Config = struct {
        port: u16,
        host: []const u8,

        pub fn init(port: u16, host: []const u8) @This() {
            return .{
                .port = port,
                .host = host,
            };
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    var config = Config.init(8000, "localhost");

    try container.registerInstance(Config, &config);

    const resolved = try container.resolve(Config);
    try std.testing.expectEqual(@as(u16, 8000), resolved.port);
    try std.testing.expectEqualStrings("localhost", resolved.host);
    try std.testing.expectEqual(&config, resolved);
}

test "custom factory" {
    const allocator = std.testing.allocator;

    const Database = struct {
        connection_string: []const u8,

        pub fn deinit(self: *@This()) void {
            _ = self;
            // cleanup would go here
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.registerFactory(Database, .singleton, struct {
        fn create(c: *Container) !*Database {
            const db = try c.allocator.create(Database);
            db.* = .{
                .connection_string = "postgresql://localhost/test",
            };
            return db;
        }
    }.create);

    const db = try container.resolve(Database);
    try std.testing.expectEqualStrings("postgresql://localhost/test", db.connection_string);
}

test "custom factory with injected dependencies" {
    const allocator = std.testing.allocator;

    const Logger = struct {
        prefix: []const u8 = "[LOG]",
    };

    const ServiceWithDeps = struct {
        logger: Injected(Logger),
        custom_value: u32,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(Logger, .singleton);
    try container.registerFactory(ServiceWithDeps, .singleton, struct {
        fn create(c: *Container) !*ServiceWithDeps {
            const svc = try c.allocator.create(ServiceWithDeps);
            svc.* = .{
                .logger = undefined, // Will be injected by the container
                .custom_value = 42,
            };
            return svc;
        }
    }.create);

    const service = try container.resolve(ServiceWithDeps);

    // Custom factory value should be set
    try std.testing.expectEqual(@as(u32, 42), service.custom_value);

    // Injected dependency should also be set
    try std.testing.expectEqualStrings("[LOG]", service.logger.get().prefix);
}

test "named registration with different lifetimes" {
    const allocator = std.testing.allocator;

    const MyService = struct {
        value: u32 = 0,
    };

    var container = Container.init(allocator);
    defer container.deinit();

    // Register the same type with different lifetimes under different names
    try container.registerNamed(MyService, "singleton_svc", .singleton);
    try container.registerNamed(MyService, "transient_svc", .transient);

    // Resolve singleton - should return same instance
    const s1 = try container.resolveNamed(MyService, "singleton_svc");
    s1.value = 100;
    const s2 = try container.resolveNamed(MyService, "singleton_svc");
    try std.testing.expectEqual(s1, s2);
    try std.testing.expectEqual(@as(u32, 100), s2.value);

    // Resolve transient - should return different instances
    const t1 = try container.resolveNamed(MyService, "transient_svc");
    const t2 = try container.resolveNamed(MyService, "transient_svc");
    try std.testing.expect(t1 != t2);
    try std.testing.expect(t1 != s1);

    // Cleanup transients
    container.destroyNamed(MyService, "transient_svc", t1);
    container.destroyNamed(MyService, "transient_svc", t2);
}

test "custom factory with lazy dependencies" {
    const allocator = std.testing.allocator;

    const HeavyService = struct {
        initialized: bool = true,
    };

    const ServiceWithLazy = struct {
        heavy: Lazy(HeavyService),
        name: []const u8,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(HeavyService, .singleton);
    try container.registerFactory(ServiceWithLazy, .singleton, struct {
        fn create(c: *Container) !*ServiceWithLazy {
            const svc = try c.allocator.create(ServiceWithLazy);
            svc.* = .{
                .heavy = undefined, // Will be injected by the container
                .name = "CustomService",
            };
            return svc;
        }
    }.create);

    const service = try container.resolve(ServiceWithLazy);

    // Custom factory value should be set
    try std.testing.expectEqualStrings("CustomService", service.name);

    // Lazy dependency should work
    const heavy = try service.heavy.get();
    try std.testing.expect(heavy.initialized);
}

test "register instance with injected dependencies" {
    const allocator = std.testing.allocator;

    const Logger = struct {
        prefix: []const u8 = "[LOG]",
    };

    const ServiceWithDeps = struct {
        logger: Injected(Logger),
        lazy_logger: Lazy(Logger),
        custom_value: u32,
    };

    var container = Container.init(allocator);
    defer container.deinit();

    // Register the dependency
    try container.register(Logger, .singleton);

    // Create an instance externally with a custom value
    var service = ServiceWithDeps{
        .logger = undefined, // Will be injected
        .lazy_logger = undefined, // Will be injected
        .custom_value = 42,
    };

    // Register the existing instance - should inject dependencies
    try container.registerInstance(ServiceWithDeps, &service);

    // Resolve and verify
    const resolved = try container.resolve(ServiceWithDeps);

    // Should be the same instance
    try std.testing.expectEqual(&service, resolved);

    // Custom value should be preserved
    try std.testing.expectEqual(@as(u32, 42), resolved.custom_value);

    // Injected dependency should be populated
    try std.testing.expectEqualStrings("[LOG]", resolved.logger.get().prefix);

    // Lazy dependency should also work
    const lazy_logger = try resolved.lazy_logger.get();
    try std.testing.expectEqualStrings("[LOG]", lazy_logger.prefix);
}

test "scoped services are shared within scope" {
    const allocator = std.testing.allocator;

    const Counter = struct {
        value: u32 = 0,

        pub fn increment(self: *@This()) void {
            self.value += 1;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.registerNamed(Counter, "scoped_counter", .scoped);

    var scope = Scope.init(&container);
    defer scope.deinit();

    const counter1 = try scope.resolveNamed(Counter, "scoped_counter");
    counter1.increment();

    const counter2 = try scope.resolveNamed(Counter, "scoped_counter");

    // Should be the same instance
    try std.testing.expectEqual(counter1, counter2);
    try std.testing.expectEqual(@as(u32, 1), counter2.value);
}

test "named scoped registration with different lifetimes" {
    const allocator = std.testing.allocator;

    const MyService = struct {
        value: u32 = 0,
    };

    var container = Container.init(allocator);
    defer container.deinit();

    // Register the same type with different lifetimes
    try container.registerNamed(MyService, "singleton_svc", .singleton);
    try container.registerNamed(MyService, "scoped_svc", .scoped);
    try container.registerNamed(MyService, "transient_svc", .transient);

    var scope1 = Scope.init(&container);
    defer scope1.deinit();

    var scope2 = Scope.init(&container);
    defer scope2.deinit();

    // Singleton - same across scopes
    const singleton1 = try scope1.resolveNamed(MyService, "singleton_svc");
    singleton1.value = 100;
    const singleton2 = try scope2.resolveNamed(MyService, "singleton_svc");
    try std.testing.expectEqual(singleton1, singleton2);

    // Scoped - same within scope, different across scopes
    const scoped1a = try scope1.resolveNamed(MyService, "scoped_svc");
    scoped1a.value = 200;
    const scoped1b = try scope1.resolveNamed(MyService, "scoped_svc");
    try std.testing.expectEqual(scoped1a, scoped1b);

    const scoped2 = try scope2.resolveNamed(MyService, "scoped_svc");
    try std.testing.expect(scoped1a != scoped2);

    // Transient - always different
    const transient1 = try scope1.resolveNamed(MyService, "transient_svc");
    const transient2 = try scope1.resolveNamed(MyService, "transient_svc");
    try std.testing.expect(transient1 != transient2);

    scope1.destroy(MyService, transient1);
    scope1.destroy(MyService, transient2);
}

test "lazy resolves scoped services correctly through scope" {
    const allocator = std.testing.allocator;

    const ScopedDep = struct {
        id: u64 = 42,
    };

    const ServiceWithLazy = struct {
        lazy_dep: Lazy(ScopedDep),
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ScopedDep, .scoped);
    try container.register(ServiceWithLazy, .scoped);

    var scope = Scope.init(&container);
    defer scope.deinit();

    const service = try scope.resolve(ServiceWithLazy);

    // Lazy resolution should go through the scope, not container
    const dep1 = try service.lazy_dep.get();
    const dep2 = try service.lazy_dep.get();

    // Should be the same scoped instance
    try std.testing.expectEqual(dep1, dep2);
    try std.testing.expectEqual(@as(u64, 42), dep1.id);

    // Direct resolution should also return the same instance
    const direct_dep = try scope.resolve(ScopedDep);
    try std.testing.expectEqual(dep1, direct_dep);
}

test "lazy resolves scoped services with registerFactory" {
    const allocator = std.testing.allocator;

    const Database = struct {
        connection_id: u64,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    const Repository = struct {
        db: Lazy(Database),
        name: []const u8,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getConnectionId(self: *@This()) !u64 {
            const db = try self.db.get();
            return db.connection_id;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    // Use registerFactory for Database with custom initialization
    try container.registerFactory(Database, .scoped, struct {
        fn create(c: *Container) !*Database {
            const db = try c.allocator.create(Database);
            db.* = .{
                .connection_id = 12345,
            };
            return db;
        }
    }.create);

    // Use registerFactory for Repository
    try container.registerFactory(Repository, .scoped, struct {
        fn create(c: *Container) !*Repository {
            const repo = try c.allocator.create(Repository);
            repo.* = .{
                .db = undefined, // Will be injected
                .name = "UserRepository",
            };
            return repo;
        }
    }.create);

    var scope = Scope.init(&container);
    defer scope.deinit();

    const repo = try scope.resolve(Repository);

    // Verify custom factory values
    try std.testing.expectEqualStrings("UserRepository", repo.name);

    // Lazy resolution should work and return scoped instance
    const conn_id = try repo.getConnectionId();
    try std.testing.expectEqual(@as(u64, 12345), conn_id);

    // Multiple lazy gets should return the same scoped instance
    const db1 = try repo.db.get();
    const db2 = try repo.db.get();
    try std.testing.expectEqual(db1, db2);

    // Direct resolution should also return the same scoped instance
    const direct_db = try scope.resolve(Database);
    try std.testing.expectEqual(db1, direct_db);
}

test "scoped dependency injection with registerFactory" {
    const allocator = std.testing.allocator;

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
        ctx: Injected(RequestContext),
        logger: Injected(Logger),
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

    var container = Container.init(allocator);
    defer container.deinit();

    // Register all services with custom factories
    try container.registerFactory(RequestContext, .scoped, struct {
        fn create(c: *Container) !*RequestContext {
            const ctx = try c.allocator.create(RequestContext);
            ctx.* = .{
                .request_id = 99999,
                .user_agent = "TestAgent/1.0",
            };
            return ctx;
        }
    }.create);

    try container.registerFactory(Logger, .scoped, struct {
        fn create(c: *Container) !*Logger {
            const logger = try c.allocator.create(Logger);
            logger.* = .{
                .prefix = "[REQUEST]",
            };
            return logger;
        }
    }.create);

    try container.registerFactory(UserService, .scoped, struct {
        fn create(c: *Container) !*UserService {
            const svc = try c.allocator.create(UserService);
            svc.* = .{
                .ctx = undefined, // Will be injected
                .logger = undefined, // Will be injected
                .service_name = "UserService",
            };
            return svc;
        }
    }.create);

    // Test with first scope
    {
        var scope = Scope.init(&container);
        defer scope.deinit();

        const user_service = try scope.resolve(UserService);

        // Verify custom factory value
        try std.testing.expectEqualStrings("UserService", user_service.service_name);

        // Verify injected dependencies work
        try std.testing.expectEqual(@as(u64, 99999), user_service.getRequestId());
        try std.testing.expectEqualStrings("[REQUEST]", user_service.getLoggerPrefix());

        // Verify scoped instances are shared
        const direct_ctx = try scope.resolve(RequestContext);
        try std.testing.expectEqual(user_service.ctx.get(), direct_ctx);

        const direct_logger = try scope.resolve(Logger);
        try std.testing.expectEqual(user_service.logger.get(), direct_logger);

        // Resolve UserService again - should be same instance
        const user_service2 = try scope.resolve(UserService);
        try std.testing.expectEqual(user_service, user_service2);
    }

    // Test with second scope - should get fresh instances
    {
        var scope2 = Scope.init(&container);
        defer scope2.deinit();

        const user_service = try scope2.resolve(UserService);

        // Should still work with fresh instances
        try std.testing.expectEqual(@as(u64, 99999), user_service.getRequestId());
        try std.testing.expectEqualStrings("[REQUEST]", user_service.getLoggerPrefix());
    }
}

test "mixed scoped and singleton with registerFactory and lazy" {
    const allocator = std.testing.allocator;

    // Singleton service
    const GlobalConfig = struct {
        app_name: []const u8,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    // Scoped service with lazy dependency on singleton
    const RequestHandler = struct {
        config: Lazy(GlobalConfig),
        request_id: u64,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn getAppName(self: *@This()) ![]const u8 {
            const cfg = try self.config.get();
            return cfg.app_name;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.registerFactory(GlobalConfig, .singleton, struct {
        fn create(c: *Container) !*GlobalConfig {
            const cfg = try c.allocator.create(GlobalConfig);
            cfg.* = .{
                .app_name = "MyApp",
            };
            return cfg;
        }
    }.create);

    try container.registerFactory(RequestHandler, .scoped, struct {
        fn create(c: *Container) !*RequestHandler {
            const handler = try c.allocator.create(RequestHandler);
            handler.* = .{
                .config = undefined, // Will be injected
                .request_id = 42,
            };
            return handler;
        }
    }.create);

    var scope1 = Scope.init(&container);
    defer scope1.deinit();

    var scope2 = Scope.init(&container);
    defer scope2.deinit();

    const handler1 = try scope1.resolve(RequestHandler);
    const handler2 = try scope2.resolve(RequestHandler);

    // Handlers should be different (scoped)
    try std.testing.expect(handler1 != handler2);

    // But they should share the same singleton config via lazy resolution
    const app_name1 = try handler1.getAppName();
    const app_name2 = try handler2.getAppName();
    try std.testing.expectEqualStrings("MyApp", app_name1);
    try std.testing.expectEqualStrings("MyApp", app_name2);

    // Verify it's the same singleton instance
    const config1 = try handler1.config.get();
    const config2 = try handler2.config.get();
    try std.testing.expectEqual(config1, config2);
}

test "different scopes get different instances" {
    const allocator = std.testing.allocator;

    const Service = struct {
        id: u64 = 0,
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(Service, .scoped);

    // Scope 1
    var scope1 = Scope.init(&container);
    const service1 = try scope1.resolve(Service);
    service1.id = 100;

    // Scope 2
    var scope2 = Scope.init(&container);
    const service2 = try scope2.resolve(Service);
    service2.id = 200;

    // Different instances
    try std.testing.expect(service1 != service2);
    try std.testing.expectEqual(@as(u64, 100), service1.id);
    try std.testing.expectEqual(@as(u64, 200), service2.id);

    scope1.deinit();
    scope2.deinit();
}

test "singletons resolved through scope come from container" {
    const allocator = std.testing.allocator;

    const GlobalConfig = struct {
        name: []const u8 = "test",
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(GlobalConfig, .singleton);

    // Resolve through container first
    const config_from_container = try container.resolve(GlobalConfig);

    // Then through scope
    var scope = Scope.init(&container);
    defer scope.deinit();

    const config_from_scope = try scope.resolve(GlobalConfig);

    // Should be the exact same instance
    try std.testing.expectEqual(config_from_container, config_from_scope);
}

test "transient services create new instances even in scope" {
    const allocator = std.testing.allocator;

    const TransientService = struct {
        value: i32 = 0,
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(TransientService, .transient);

    var scope = Scope.init(&container);
    defer scope.deinit();

    const service1 = try scope.resolve(TransientService);
    const service2 = try scope.resolve(TransientService);

    // Should be different instances
    try std.testing.expect(service1 != service2);

    // Clean up transient instances
    scope.destroy(TransientService, service1);
    scope.destroy(TransientService, service2);
}

test "scoped dependency injection" {
    const allocator = std.testing.allocator;

    const RequestContext = struct {
        request_id: u64 = 12345,
    };

    const UserService = struct {
        ctx: Injected(RequestContext),
        name: []const u8 = "UserService",
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(RequestContext, .scoped);
    try container.register(UserService, .scoped);

    var scope = Scope.init(&container);
    defer scope.deinit();

    const user_service = try scope.resolve(UserService);

    try std.testing.expectEqual(@as(u64, 12345), user_service.ctx.get().request_id);
    try std.testing.expectEqualStrings("UserService", user_service.name);

    // The injected RequestContext should be the same as directly resolved
    const direct_ctx = try scope.resolve(RequestContext);
    try std.testing.expectEqual(user_service.ctx.get(), direct_ctx);
}

test "scope instances are destroyed on deinit" {
    const allocator = std.testing.allocator;

    // We can't easily test destruction directly, but we can verify
    // the scope cleans up without memory leaks (allocator will detect)
    const DestructibleService = struct {
        data: []u8,
        allocator_ref: std.mem.Allocator,

        pub fn deinit(self: *@This()) void {
            self.allocator_ref.free(self.data);
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.registerFactory(DestructibleService, .scoped, struct {
        fn create(c: *Container) !*DestructibleService {
            const service = try c.allocator.create(DestructibleService);
            service.* = .{
                .data = try c.allocator.alloc(u8, 1024),
                .allocator_ref = c.allocator,
            };
            return service;
        }
    }.create);

    {
        var scope = Scope.init(&container);
        defer scope.deinit(); // Should clean up the allocated data

        _ = try scope.resolve(DestructibleService);
    }

    // If we get here without memory leak errors, destruction worked
}

// ============================================================================
// Tests for init function signatures
// ============================================================================

test "init with no parameters" {
    const allocator = std.testing.allocator;

    // Static counter to track if init was called
    const ServiceWithStaticInit = struct {
        var init_called: bool = false;

        value: u32 = 100,

        pub fn init() void {
            init_called = true;
        }
    };

    // Reset static state
    ServiceWithStaticInit.init_called = false;

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithStaticInit, .singleton);

    const service = try container.resolve(ServiceWithStaticInit);

    // init() should have been called
    try std.testing.expect(ServiceWithStaticInit.init_called);
    // Default value should be preserved
    try std.testing.expectEqual(@as(u32, 100), service.value);
}

test "init with self pointer" {
    const allocator = std.testing.allocator;

    const ServiceWithSelfInit = struct {
        value: u32 = 0,
        initialized: bool = false,

        pub fn init(self: *@This()) void {
            self.value = 42;
            self.initialized = true;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithSelfInit, .singleton);

    const service = try container.resolve(ServiceWithSelfInit);

    // init(self) should have modified the instance
    try std.testing.expect(service.initialized);
    try std.testing.expectEqual(@as(u32, 42), service.value);
}

test "init with allocator only" {
    const allocator = std.testing.allocator;

    // Static to track init was called with an allocator
    const ServiceWithAllocatorInit = struct {
        var received_allocator: bool = false;

        value: u32 = 200,

        pub fn init(alloc: std.mem.Allocator) void {
            // Just verify we received a valid allocator by checking it's usable
            _ = alloc;
            received_allocator = true;
        }
    };

    // Reset static state
    ServiceWithAllocatorInit.received_allocator = false;

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithAllocatorInit, .singleton);

    const service = try container.resolve(ServiceWithAllocatorInit);

    // init(allocator) should have been called
    try std.testing.expect(ServiceWithAllocatorInit.received_allocator);
    // Default value should be preserved
    try std.testing.expectEqual(@as(u32, 200), service.value);
}

test "init with self and allocator" {
    const allocator = std.testing.allocator;

    const ServiceWithFullInit = struct {
        data: ?[]u8 = null,
        allocator_ref: ?std.mem.Allocator = null,
        initialized: bool = false,

        pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
            self.allocator_ref = alloc;
            self.data = alloc.alloc(u8, 10) catch null;
            self.initialized = true;
        }

        pub fn deinit(self: *@This()) void {
            if (self.data) |d| {
                if (self.allocator_ref) |alloc| {
                    alloc.free(d);
                }
            }
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithFullInit, .singleton);

    const service = try container.resolve(ServiceWithFullInit);

    // init(self, allocator) should have modified the instance
    try std.testing.expect(service.initialized);
    try std.testing.expect(service.data != null);
    try std.testing.expectEqual(@as(usize, 10), service.data.?.len);
    try std.testing.expect(service.allocator_ref != null);
}

test "init with self pointer and injected dependencies" {
    const allocator = std.testing.allocator;

    const Config = struct {
        base_value: u32 = 10,
    };

    const ServiceWithInitAndDeps = struct {
        config: Injected(Config),
        computed_value: u32 = 0,
        init_called: bool = false,

        pub fn init(self: *@This()) void {
            // Access injected dependency during init
            self.computed_value = self.config.get().base_value * 2;
            self.init_called = true;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(Config, .singleton);
    try container.register(ServiceWithInitAndDeps, .singleton);

    const service = try container.resolve(ServiceWithInitAndDeps);

    // init should have been called after dependency injection
    try std.testing.expect(service.init_called);
    // computed_value should be based on injected config
    try std.testing.expectEqual(@as(u32, 20), service.computed_value);
}

test "init with self and allocator plus injected dependencies" {
    const allocator = std.testing.allocator;

    const Logger = struct {
        prefix: []const u8 = "[LOG]",
    };

    const ServiceWithEverything = struct {
        logger: Injected(Logger),
        buffer: ?[]u8 = null,
        allocator_ref: ?std.mem.Allocator = null,
        message: []const u8 = "",

        pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
            self.allocator_ref = alloc;
            self.buffer = alloc.alloc(u8, 64) catch null;
            // Access injected dependency
            self.message = self.logger.get().prefix;
        }

        pub fn deinit(self: *@This()) void {
            if (self.buffer) |b| {
                if (self.allocator_ref) |alloc| {
                    alloc.free(b);
                }
            }
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(Logger, .singleton);
    try container.register(ServiceWithEverything, .singleton);

    const service = try container.resolve(ServiceWithEverything);

    // Verify init was called with allocator
    try std.testing.expect(service.buffer != null);
    try std.testing.expect(service.allocator_ref != null);
    // Verify injected dependency was accessible in init
    try std.testing.expectEqualStrings("[LOG]", service.message);
}

// ============================================================================
// Tests for init functions that return values (error unions and factory-style)
// ============================================================================

test "init with self pointer returning error union" {
    const allocator = std.testing.allocator;

    const ServiceWithFallibleInit = struct {
        value: u32 = 0,
        initialized: bool = false,

        pub fn init(self: *@This()) !void {
            self.value = 99;
            self.initialized = true;
            // Could return an error here in real code
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithFallibleInit, .singleton);

    const service = try container.resolve(ServiceWithFallibleInit);

    try std.testing.expect(service.initialized);
    try std.testing.expectEqual(@as(u32, 99), service.value);
}

test "init with self and allocator returning error union" {
    const allocator = std.testing.allocator;

    const ServiceWithFallibleFullInit = struct {
        data: ?[]u8 = null,
        allocator_ref: ?std.mem.Allocator = null,

        pub fn init(self: *@This(), alloc: std.mem.Allocator) !void {
            self.allocator_ref = alloc;
            self.data = try alloc.alloc(u8, 32);
        }

        pub fn deinit(self: *@This()) void {
            if (self.data) |d| {
                if (self.allocator_ref) |alloc| {
                    alloc.free(d);
                }
            }
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithFallibleFullInit, .singleton);

    const service = try container.resolve(ServiceWithFallibleFullInit);

    try std.testing.expect(service.data != null);
    try std.testing.expectEqual(@as(usize, 32), service.data.?.len);
}

test "factory-style init returning T" {
    const allocator = std.testing.allocator;

    const FactoryService = struct {
        value: u32,
        name: []const u8,

        pub fn init() @This() {
            return .{
                .value = 123,
                .name = "factory-created",
            };
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(FactoryService, .singleton);

    const service = try container.resolve(FactoryService);

    try std.testing.expectEqual(@as(u32, 123), service.value);
    try std.testing.expectEqualStrings("factory-created", service.name);
}

test "factory-style init with allocator returning T" {
    const allocator = std.testing.allocator;

    const FactoryWithAllocator = struct {
        buffer: []u8,
        allocator_ref: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .buffer = alloc.alloc(u8, 64) catch &[_]u8{},
                .allocator_ref = alloc,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.buffer.len > 0) {
                self.allocator_ref.free(self.buffer);
            }
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(FactoryWithAllocator, .singleton);

    const service = try container.resolve(FactoryWithAllocator);

    try std.testing.expectEqual(@as(usize, 64), service.buffer.len);
}

test "factory-style init with allocator returning error union !T" {
    const allocator = std.testing.allocator;

    const FallibleFactory = struct {
        data: []u8,
        allocator_ref: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            const data = try alloc.alloc(u8, 128);
            return .{
                .data = data,
                .allocator_ref = alloc,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator_ref.free(self.data);
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(FallibleFactory, .singleton);

    const service = try container.resolve(FallibleFactory);

    try std.testing.expectEqual(@as(usize, 128), service.data.len);
}

test "factory-style init with injected dependencies" {
    const allocator = std.testing.allocator;

    const Config = struct {
        buffer_size: usize = 256,
    };

    const FactoryWithDeps = struct {
        config: Injected(Config),
        buffer: []u8,
        allocator_ref: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            // Note: config is NOT available here since this is factory-style
            // It will be injected AFTER init returns
            const buffer = try alloc.alloc(u8, 64);
            return .{
                .config = undefined, // Will be injected after
                .buffer = buffer,
                .allocator_ref = alloc,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator_ref.free(self.buffer);
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(Config, .singleton);
    try container.register(FactoryWithDeps, .singleton);

    const service = try container.resolve(FactoryWithDeps);

    // Factory created the buffer
    try std.testing.expectEqual(@as(usize, 64), service.buffer.len);
    // Injected dependency should be populated after factory returned
    try std.testing.expectEqual(@as(usize, 256), service.config.get().buffer_size);
}

test "init returning error propagates correctly" {
    const allocator = std.testing.allocator;

    const FailingService = struct {
        pub fn init(self: *@This()) !void {
            _ = self;
            return error.InitializationFailed;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(FailingService, .singleton);

    const result = container.resolve(FailingService);
    try std.testing.expectError(error.InitializationFailed, result);
}

test "factory-style init returning error propagates correctly" {
    const allocator = std.testing.allocator;

    const FailingFactory = struct {
        value: u32,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            _ = alloc;
            return error.FactoryFailed;
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(FailingFactory, .singleton);

    const result = container.resolve(FailingFactory);
    try std.testing.expectError(error.FactoryFailed, result);
}

test "init with self pointer returning T" {
    const allocator = std.testing.allocator;

    const ServiceWithSelfReturningT = struct {
        value: u32 = 0,
        name: []const u8 = "",

        pub fn init(self: *@This()) @This() {
            _ = self; // Could use current state if needed
            return .{
                .value = 999,
                .name = "rebuilt",
            };
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithSelfReturningT, .singleton);

    const service = try container.resolve(ServiceWithSelfReturningT);

    try std.testing.expectEqual(@as(u32, 999), service.value);
    try std.testing.expectEqualStrings("rebuilt", service.name);
}

test "init with self pointer returning !T" {
    const allocator = std.testing.allocator;

    const ServiceWithSelfReturningErrorT = struct {
        value: u32 = 0,

        pub fn init(self: *@This()) !@This() {
            const old_value = self.value;
            return .{
                .value = old_value + 100,
            };
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithSelfReturningErrorT, .singleton);

    const service = try container.resolve(ServiceWithSelfReturningErrorT);

    // Default was 0, init added 100
    try std.testing.expectEqual(@as(u32, 100), service.value);
}

test "init with self and allocator returning T" {
    const allocator = std.testing.allocator;

    const ServiceWithFullReturningT = struct {
        buffer: []u8,
        allocator_ref: std.mem.Allocator,

        pub fn init(self: *@This(), alloc: std.mem.Allocator) @This() {
            _ = self;
            return .{
                .buffer = alloc.alloc(u8, 50) catch &[_]u8{},
                .allocator_ref = alloc,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.buffer.len > 0) {
                self.allocator_ref.free(self.buffer);
            }
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithFullReturningT, .singleton);

    const service = try container.resolve(ServiceWithFullReturningT);

    try std.testing.expectEqual(@as(usize, 50), service.buffer.len);
}

test "init with self and allocator returning !T" {
    const allocator = std.testing.allocator;

    const ServiceWithFullReturningErrorT = struct {
        data: []u8,
        allocator_ref: std.mem.Allocator,

        pub fn init(self: *@This(), alloc: std.mem.Allocator) !@This() {
            _ = self;
            const data = try alloc.alloc(u8, 75);
            return .{
                .data = data,
                .allocator_ref = alloc,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator_ref.free(self.data);
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(ServiceWithFullReturningErrorT, .singleton);

    const service = try container.resolve(ServiceWithFullReturningErrorT);

    try std.testing.expectEqual(@as(usize, 75), service.data.len);
}

test "init with self pointer returning T with injected dependencies" {
    const allocator = std.testing.allocator;

    const Config = struct {
        multiplier: u32 = 5,
    };

    const ServiceWithSelfReturningTAndDeps = struct {
        config: Injected(Config),
        value: u32 = 10,

        pub fn init(self: *@This()) @This() {
            // Note: dependencies are injected before init, so we can use them
            const multiplied = self.value * self.config.get().multiplier;
            return .{
                .config = undefined, // Will be re-injected after
                .value = multiplied,
            };
        }
    };

    var container = Container.init(allocator);
    defer container.deinit();

    try container.register(Config, .singleton);
    try container.register(ServiceWithSelfReturningTAndDeps, .singleton);

    const service = try container.resolve(ServiceWithSelfReturningTAndDeps);

    // Default value 10 * multiplier 5 = 50
    try std.testing.expectEqual(@as(u32, 50), service.value);
    // Config should be re-injected
    try std.testing.expectEqual(@as(u32, 5), service.config.get().multiplier);
}
