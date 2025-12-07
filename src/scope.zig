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
                const instance = try entry.create_fn.?(self.container);
                try self.scoped_instances.put(key, .{
                    .instance = instance,
                    .destroy_fn = entry.destroy_fn,
                });
                return instance;
            },
            .transient => {
                return try entry.create_fn.?(self.container);
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
                const instance: *T = if (entry.uses_custom_factory and !entry.instance_type) blk: {
                    const inst: *T = @ptrCast(@alignCast(try entry.create_fn.?(self.container)));
                    // Inject Lazy/Injected fields even for custom factories
                    try self.injectFields(T, inst);
                    break :blk inst;
                } else if (entry.instance_type) {
                    const inst: *T = @ptrCast(@alignCast(entry.instance.?));
                    return inst;
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
                return if (entry.uses_custom_factory and !entry.instance_type) {
                    const inst: *T = @ptrCast(@alignCast(try entry.create_fn.?(self.container)));
                    // Inject Lazy/Injected fields even for custom factories
                    try self.injectFields(T, inst);
                    return inst;
                } else if (entry.instance_type) {
                    const instance: *T = @ptrCast(@alignCast(entry.instance.?));
                    return instance;
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
