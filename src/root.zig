const std = @import("std");

pub const Scope = @import("scope.zig").Scope;

pub const Lifetime = enum {
    /// Single instance shared across all resolutions
    singleton,
    /// New instance created for each resolution
    transient,
    /// Single instance within a scope
    scoped,
};

/// Resolver interface - can be either a Container or a Scope
/// This allows Lazy(T) to work correctly in both contexts
pub const Resolver = struct {
    ptr: *anyopaque,
    resolveFn: *const fn (*anyopaque, []const u8) anyerror!*anyopaque,

    pub fn resolve(self: Resolver, comptime T: type) !*T {
        const result = try self.resolveFn(self.ptr, @typeName(T));
        return @ptrCast(@alignCast(result));
    }

    /// Create a Resolver from a Container
    pub fn fromContainer(container: *Container) Resolver {
        return .{
            .ptr = @ptrCast(container),
            .resolveFn = &struct {
                fn resolve(ctx: *anyopaque, key: []const u8) anyerror!*anyopaque {
                    const c: *Container = @ptrCast(@alignCast(ctx));
                    return c.resolveByKey(key);
                }
            }.resolve,
        };
    }

    /// Create a Resolver from a Scope
    pub fn fromScope(scope: *Scope) Resolver {
        return .{
            .ptr = @ptrCast(scope),
            .resolveFn = &struct {
                fn resolve(ctx: *anyopaque, key: []const u8) anyerror!*anyopaque {
                    const s: *Scope = @ptrCast(@alignCast(ctx));
                    return s.resolveByKey(key);
                }
            }.resolve,
        };
    }
};

/// Lazy wrapper for deferred dependency resolution.
/// The dependency is only resolved when `get()` is called.
/// Works correctly in both Container and Scope contexts.
pub fn Lazy(comptime T: type) type {
    return struct {
        pub const Inner = T;

        _resolver: Resolver,

        pub fn get(self: @This()) !*T {
            return self._resolver.resolve(T);
        }
    };
}

/// Wrapper for eagerly-resolved dependencies.
/// The dependency is resolved immediately during injection.
pub fn Injected(comptime T: type) type {
    return struct {
        pub const Inner = T;

        ptr: *T,

        pub fn get(self: @This()) *T {
            return self.ptr;
        }
    };
}

/// Type-erased service entry stored at runtime
const ServiceEntry = struct {
    create_fn: *const fn (*Container) anyerror!*anyopaque,
    destroy_fn: ?*const fn (std.mem.Allocator, *anyopaque) void,
    lifetime: Lifetime,
    instance: ?*anyopaque,
    uses_custom_factory: bool,
};

/// Dependency Injection Container
///
/// Example usage:
/// ```
/// const Container = @import("di").Container;
///
/// const Logger = struct {
///     pub fn log(self: *Logger, msg: []const u8) void { _ = self; _ = msg; }
/// };
///
/// const UserService = struct {
///     logger: Injected(Logger),
///
///     pub fn doSomething(self: *UserService) void {
///         self.logger.get().log("doing something");
///     }
/// };
///
/// var container = Container.init(allocator);
/// defer container.deinit();
///
/// try container.register(Logger, .singleton);
/// try container.register(UserService, .transient);
///
/// const service = try container.resolve(UserService);
/// service.doSomething();
/// ```
pub const Container = struct {
    allocator: std.mem.Allocator,
    services: std.StringHashMap(ServiceEntry),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Container {
        return .{
            .allocator = allocator,
            .services = std.StringHashMap(ServiceEntry).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Container) void {
        // Destroy all singleton instances
        var iter = self.services.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.instance) |inst| {
                if (kv.value_ptr.destroy_fn) |destroy_fn| {
                    destroy_fn(self.allocator, inst);
                }
            }
        }
        self.services.deinit();
    }

    /// Register a type with the container using automatic construction.
    /// The type's fields will be inspected and dependencies will be injected.
    pub fn register(self: *Container, comptime T: type, lifetime: Lifetime) !void {
        try self.registerNamed(T, @typeName(T), lifetime);
    }

    /// Register a type with a custom name.
    /// This allows registering the same type multiple times with different lifetimes.
    ///
    /// Example:
    /// ```
    /// try container.registerNamed(MyService, "singleton_service", .singleton);
    /// try container.registerNamed(MyService, "transient_service", .transient);
    /// try container.registerNamed(MyService, "scoped_service", .scoped);
    ///
    /// const s1 = try container.resolveNamed(MyService, "singleton_service");
    /// const s2 = try container.resolveNamed(MyService, "transient_service");
    /// ```
    pub fn registerNamed(self: *Container, comptime T: type, name: []const u8, lifetime: Lifetime) !void {
        const entry = ServiceEntry{
            .create_fn = &makeCreateFn(T).create,
            .destroy_fn = &makeDestroyFn(T).destroy,
            .lifetime = lifetime,
            .instance = null,
            .uses_custom_factory = false,
        };
        try self.services.put(name, entry);
    }

    /// Register a type with a custom factory function.
    pub fn registerFactory(
        self: *Container,
        comptime T: type,
        lifetime: Lifetime,
        comptime factory: fn (*Container) anyerror!*T,
    ) !void {
        try self.registerFactoryNamed(T, @typeName(T), lifetime, factory);
    }

    /// Register a type with a custom factory function and a custom name.
    pub fn registerFactoryNamed(
        self: *Container,
        comptime T: type,
        name: []const u8,
        lifetime: Lifetime,
        comptime factory: fn (*Container) anyerror!*T,
    ) !void {
        const entry = ServiceEntry{
            .create_fn = &struct {
                fn create(container: *Container) anyerror!*anyopaque {
                    return @ptrCast(try factory(container));
                }
            }.create,
            .destroy_fn = &makeDestroyFn(T).destroy,
            .lifetime = lifetime,
            .instance = null,
            .uses_custom_factory = true,
        };
        try self.services.put(name, entry);
    }

    /// Register an existing instance as a singleton.
    pub fn registerInstance(self: *Container, comptime T: type, instance: *T) !void {
        try self.registerInstanceNamed(T, @typeName(T), instance);
    }

    /// Register an existing instance as a singleton with a custom name.
    pub fn registerInstanceNamed(self: *Container, comptime T: type, name: []const u8, instance: *T) !void {
        // Inject Lazy/Injected fields into the provided instance
        try self.injectFieldsInternal(T, instance);

        const entry = ServiceEntry{
            .create_fn = &makeCreateFn(T).create,
            .destroy_fn = null, // Don't destroy externally-provided instances
            .lifetime = .singleton,
            .instance = @ptrCast(instance),
            .uses_custom_factory = false,
        };
        try self.services.put(name, entry);
    }

    /// Resolve a service from the container.
    pub fn resolve(self: *Container, comptime T: type) !*T {
        return self.resolveNamed(T, @typeName(T));
    }

    /// Resolve a service by its registered name.
    /// Use this when you have multiple registrations of the same type.
    pub fn resolveNamed(self: *Container, comptime T: type, name: []const u8) !*T {
        return self.resolveNamedInternal(T, name, false);
    }

    /// Resolve a service by its string key (used by Resolver interface)
    pub fn resolveByKey(self: *Container, key: []const u8) anyerror!*anyopaque {
        const entry = self.services.getPtr(key) orelse return error.ServiceNotRegistered;

        switch (entry.lifetime) {
            .singleton => {
                if (entry.instance) |ptr| {
                    return ptr;
                }
                self.mutex.lock();
                defer self.mutex.unlock();
                if (entry.instance) |ptr| {
                    return ptr;
                }
                const new = try entry.create_fn(self);
                entry.instance = new;
                return new;
            },
            .transient => {
                return try entry.create_fn(self);
            },
            .scoped => return error.UseAScopedResolver,
        }
    }

    /// Create a new scope for scoped lifetime services.
    /// The scope must be deinitialized when done to clean up scoped instances.
    pub fn createScope(self: *Container) Scope {
        return Scope.init(self);
    }

    /// Get a Resolver interface for this container
    pub fn resolver(self: *Container) Resolver {
        return Resolver.fromContainer(self);
    }

    // Internal resolve that tracks whether we already hold the lock
    fn resolveInternal(self: *Container, comptime T: type, already_locked: bool) !*T {
        return self.resolveNamedInternal(T, @typeName(T), already_locked);
    }

    // Internal resolve by name that tracks whether we already hold the lock
    fn resolveNamedInternal(self: *Container, comptime T: type, name: []const u8, already_locked: bool) !*T {
        const entry = self.services.getPtr(name) orelse return error.ServiceNotRegistered;

        switch (entry.lifetime) {
            .singleton => {
                // Fast path: already created
                if (entry.instance) |ptr| {
                    return @ptrCast(@alignCast(ptr));
                }

                // Only lock if we don't already hold it
                const need_unlock = !already_locked;
                if (need_unlock) {
                    self.mutex.lock();
                }
                defer if (need_unlock) {
                    self.mutex.unlock();
                };

                // Double-check after acquiring lock
                if (entry.instance) |ptr| {
                    return @ptrCast(@alignCast(ptr));
                }

                const new: *T = if (entry.uses_custom_factory) blk: {
                    const instance: *T = @ptrCast(@alignCast(try entry.create_fn(self)));
                    // Inject Lazy/Injected fields even for custom factories
                    try self.injectFieldsInternal(T, instance);
                    break :blk instance;
                } else try self.buildInstanceInternal(T);
                entry.instance = @ptrCast(new);
                return new;
            },
            .transient => {
                const new: *T = if (entry.uses_custom_factory) blk: {
                    const instance: *T = @ptrCast(@alignCast(try entry.create_fn(self)));
                    // Inject Lazy/Injected fields even for custom factories
                    try self.injectFieldsInternal(T, instance);
                    break :blk instance;
                } else try self.buildInstanceInternal(T);
                return new;
            },
            .scoped => return error.UseAScopedResolver,
        }
    }

    /// Check if a service is registered.
    pub fn isRegistered(self: *Container, comptime T: type) bool {
        return self.services.contains(@typeName(T));
    }

    /// Destroy a transient instance that was previously resolved.
    pub fn destroy(self: *Container, comptime T: type, instance: *T) void {
        self.destroyNamed(T, @typeName(T), instance);
    }

    /// Destroy a transient instance that was resolved by name.
    pub fn destroyNamed(self: *Container, comptime T: type, name: []const u8, instance: *T) void {
        if (self.services.get(name)) |entry| {
            if (entry.destroy_fn) |destroy_fn| {
                destroy_fn(self.allocator, @ptrCast(instance));
            }
        } else {
            // Fallback: just destroy using allocator if service not found
            if (@hasDecl(T, "deinit")) {
                instance.deinit();
            }
            self.allocator.destroy(instance);
        }
    }

    // Internal: Generate a create function for type T
    fn makeCreateFn(comptime T: type) type {
        return struct {
            fn create(container: *Container) anyerror!*anyopaque {
                return @ptrCast(try container.buildInstanceInternal(T));
            }
        };
    }

    // Internal: Generate a destroy function for type T
    fn makeDestroyFn(comptime T: type) type {
        return struct {
            fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                if (@hasDecl(T, "deinit")) {
                    typed.deinit();
                }
                allocator.destroy(typed);
            }
        };
    }

    // Internal: Build an instance of T, injecting dependencies
    fn buildInstanceInternal(self: *Container, comptime T: type) !*T {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError("DI can only build structs, got: " ++ @typeName(T));
        }

        const instance = try self.allocator.create(T);
        errdefer self.allocator.destroy(instance);

        // Start with default values if available
        instance.* = getDefaults(T);

        // Inject dependencies into marked fields (we're already locked for singletons)
        try self.injectFieldsInternal(T, instance);

        // Call init if it exists and takes *Self
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

    fn injectFieldsInternal(self: *Container, comptime T: type, instance: *T) !void {
        const info = @typeInfo(T).@"struct";

        inline for (info.fields) |field| {
            const FieldType = field.type;
            const field_info = @typeInfo(FieldType);

            if (field_info == .@"struct" and @hasDecl(FieldType, "Inner")) {
                // Check for Lazy(X)
                if (FieldType == Lazy(FieldType.Inner)) {
                    @field(instance, field.name) = .{
                        ._resolver = Resolver.fromContainer(self),
                    };
                }
                // Check for Injected(X)
                else if (FieldType == Injected(FieldType.Inner)) {
                    // Pass true to indicate we already hold the lock
                    const dep = try self.resolveInternal(FieldType.Inner, true);
                    @field(instance, field.name) = .{
                        .ptr = dep,
                    };
                }
            }
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

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
    };

    var container = Container.init(allocator);
    defer container.deinit();

    var config = Config{
        .port = 8080,
        .host = "localhost",
    };

    try container.registerInstance(Config, &config);

    const resolved = try container.resolve(Config);
    try std.testing.expectEqual(@as(u16, 8080), resolved.port);
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
