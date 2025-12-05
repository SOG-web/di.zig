const std = @import("std");

const root = @import("root.zig");
const Container = root.Container;
const Lifetime = root.Lifetime;
const Lazy = root.Lazy;
const Injected = root.Injected;
const Resolver = root.Resolver;

/// A scoped instance entry - stores the instance and its destroy function
const ScopedEntry = struct {
    instance: *anyopaque,
    destroy_fn: ?*const fn (std.mem.Allocator, *anyopaque) void,
};

/// A Scope represents a bounded lifetime for scoped services.
///
/// Services registered with `.scoped` lifetime will have one instance
/// per Scope. When the Scope is deinitialized, all scoped instances
/// are destroyed.
pub const Scope = struct {
    container: *Container,
    scoped_instances: std.StringHashMap(ScopedEntry),
    allocator: std.mem.Allocator,

    /// Create a new scope from a container.
    pub fn init(container: *Container) Scope {
        return .{
            .container = container,
            .scoped_instances = std.StringHashMap(ScopedEntry).init(container.allocator),
            .allocator = container.allocator,
        };
    }

    /// Destroy the scope and all scoped instances.
    /// Singleton instances are NOT destroyed (they belong to the container).
    /// Transient instances are NOT tracked (caller is responsible).
    pub fn deinit(self: *Scope) void {
        // Destroy all scoped instances in reverse order would be ideal,
        // but am not sure if StringHashMap preserve insertion order.
        // For proper ordering, consider using an ArrayList alongside the map.
        var iter = self.scoped_instances.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.destroy_fn) |destroy_fn| {
                destroy_fn(self.allocator, kv.value_ptr.instance);
            }
        }
        self.scoped_instances.deinit();
    }

    /// Resolve a service from this scope.
    ///
    /// - Singletons are resolved from the parent container
    /// - Scoped services are cached in this scope
    /// - Transient services create new instances each time
    pub fn resolve(self: *Scope, comptime T: type) !*T {
        return self.resolveNamed(T, @typeName(T));
    }

    /// Resolve a service by its registered name.
    /// Use this when you have multiple registrations of the same type.
    pub fn resolveNamed(self: *Scope, comptime T: type, name: []const u8) !*T {
        return self.resolveNamedInternal(T, name);
    }

    /// Resolve a service by its string key (used by Resolver interface)
    pub fn resolveByKey(self: *Scope, key: []const u8) anyerror!*anyopaque {
        const entry = self.container.services.getPtr(key) orelse return error.ServiceNotRegistered;

        switch (entry.lifetime) {
            .singleton => {
                // Delegate to container for singletons
                return self.container.resolveByKey(key);
            },
            .scoped => {
                if (self.scoped_instances.get(key)) |scoped_entry| {
                    return scoped_entry.instance;
                }
                // For runtime resolution, we must use the factory
                const instance = try entry.create_fn(self.container);
                try self.scoped_instances.put(key, .{
                    .instance = instance,
                    .destroy_fn = entry.destroy_fn,
                });
                return instance;
            },
            .transient => {
                return try entry.create_fn(self.container);
            },
        }
    }

    /// Get a Resolver interface for this scope
    pub fn resolver(self: *Scope) Resolver {
        return Resolver.fromScope(self);
    }

    fn resolveInternal(self: *Scope, comptime T: type) !*T {
        return self.resolveNamedInternal(T, @typeName(T));
    }

    fn resolveNamedInternal(self: *Scope, comptime T: type, name: []const u8) !*T {
        // Get the service entry from the parent container
        const entry = self.container.services.getPtr(name) orelse return error.ServiceNotRegistered;

        switch (entry.lifetime) {
            .singleton => {
                // Delegate to container for singletons, using the same name
                return self.container.resolveNamed(T, name);
            },
            .scoped => {
                // Check if already created in this scope
                if (self.scoped_instances.get(name)) |scoped_entry| {
                    return @ptrCast(@alignCast(scoped_entry.instance));
                }

                // Create new instance for this scope
                // Use custom factory if registered, otherwise build manually
                const instance: *T = if (entry.uses_custom_factory) blk: {
                    const inst: *T = @ptrCast(@alignCast(try entry.create_fn(self.container)));
                    // Inject Lazy/Injected fields even for custom factories
                    try self.injectFields(T, inst);
                    break :blk inst;
                } else try self.buildScopedInstance(T);

                try self.scoped_instances.put(name, .{
                    .instance = @ptrCast(instance),
                    .destroy_fn = entry.destroy_fn,
                });

                return instance;
            },
            .transient => {
                // Always create new instance
                // Use custom factory if registered, otherwise build manually
                return if (entry.uses_custom_factory) blk: {
                    const inst: *T = @ptrCast(@alignCast(try entry.create_fn(self.container)));
                    // Inject Lazy/Injected fields even for custom factories
                    try self.injectFields(T, inst);
                    break :blk inst;
                } else try self.buildScopedInstance(T);
            },
        }
    }

    /// Build an instance, injecting dependencies from this scope
    fn buildScopedInstance(self: *Scope, comptime T: type) !*T {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError("DI can only build structs, got: " ++ @typeName(T));
        }

        const instance = try self.allocator.create(T);
        errdefer self.allocator.destroy(instance);

        // Initialize with defaults
        instance.* = getDefaults(T);

        // Inject dependencies (resolve through scope, not container)
        try self.injectFields(T, instance);

        // Call init if available
        if (@hasDecl(T, "init")) {
            const InitFn = @TypeOf(T.init);
            const init_info = @typeInfo(InitFn);
            if (init_info == .@"fn") {
                const params = init_info.@"fn".params;
                if (params.len == 1 and params[0].type == *T) {
                    T.init(instance);
                }
            }
        }

        return instance;
    }

    fn getDefaults(comptime T: type) T {
        const info = @typeInfo(T).@"struct";
        var result: T = undefined;
        inline for (info.fields) |field| {
            if (field.default_value_ptr) |default_ptr| {
                const typed_ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = typed_ptr.*;
            }
        }
        return result;
    }

    fn injectFields(self: *Scope, comptime T: type, instance: *T) !void {
        const info = @typeInfo(T).@"struct";

        inline for (info.fields) |field| {
            const FieldType = field.type;
            const field_info = @typeInfo(FieldType);

            if (field_info == .@"struct" and @hasDecl(FieldType, "Inner")) {
                // Check for Lazy(X) - uses Resolver to support both Container and Scope
                if (FieldType == Lazy(FieldType.Inner)) {
                    @field(instance, field.name) = .{
                        ._resolver = Resolver.fromScope(self),
                    };
                }
                // Check for Injected(X) - resolved eagerly through scope
                else if (FieldType == Injected(FieldType.Inner)) {
                    const dep = try self.resolveInternal(FieldType.Inner);
                    @field(instance, field.name) = .{
                        .ptr = dep,
                    };
                }
            }
        }
    }

    /// Manually destroy a transient instance that was resolved from this scope.
    /// This is needed because transient instances are not tracked.
    pub fn destroy(self: *Scope, comptime T: type, instance: *T) void {
        if (@hasDecl(T, "deinit")) {
            instance.deinit();
        }
        self.allocator.destroy(instance);
    }
};

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
