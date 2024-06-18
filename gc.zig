const std = @import("std");

const STACK_MAX = 256;
const INITIAL_GC_THRESHOLD = 8;

const VM = struct {
    stack: std.ArrayList(*Object),
    stackSize: u9,
    allocator: std.mem.Allocator,
    firstObject: ?*Object,
    numObjects: u32,
    maxObjects: u32,

    fn newObject(self: *VM, allocator: std.mem.Allocator, t: ObjectType) !*Object {
        const obj = try allocator.create(Object);

        obj.type = t;
        obj.value = switch (obj.type) {
            ObjectType.OBJ_INT => ObjectUnion{ .OBJ_INT = 0 },
            ObjectType.OBJ_PAIR => ObjectUnion{ .OBJ_PAIR = undefined },
        };

        obj.next = self.firstObject;
        self.firstObject = obj;

        self.numObjects += 1;

        return obj;
    }

    fn push(self: *VM, value: *Object) void {
        assert(self.stackSize < STACK_MAX, "stack overflow");
        self.stack.appendAssumeCapacity(value);
        self.stackSize += 1;
    }

    fn pop(self: *VM) !*Object {
        assert(self.stackSize > 0, "stack underflow");
        self.stackSize -= 1;

        const value = self.stack.items[self.stackSize];
        try self.stack.resize(self.stackSize);
        return value;
    }

    fn pushInt(self: *VM, value: i32) !*Object {
        var object = try self.newObject(self.allocator, ObjectType.OBJ_INT);
        object.value.OBJ_INT = value;
        self.push(object);
        return object;
    }

    fn pushPair(self: *VM) !*Object {
        var object = try self.newObject(self.allocator, ObjectType.OBJ_PAIR);
        object.value.OBJ_PAIR.head = try self.pop();
        object.value.OBJ_PAIR.tail = try self.pop();
        self.push(object);
        return object;
    }

    fn markAll(self: *VM) void {
        if (self.stackSize <= 0) return;
        for (self.stack.items) |object| object.mark();
    }

    fn sweep(self: *VM) void {
        var object = self.firstObject;
        while (object) |pointer| {
            object = pointer.next;
            if (!pointer.marked) {
                self.allocator.destroy(pointer);
                self.numObjects -= 1;
            } else {
                pointer.marked = false;
            }
        }
    }

    fn gc(self: *VM) void {
        const currentNumObjects = self.numObjects;

        self.markAll();
        self.sweep();

        self.maxObjects = self.numObjects * 2;

        std.debug.print("Collected {d} objects, {d} remaining.\n", .{ currentNumObjects - self.numObjects, self.numObjects });
    }
};

fn newVM(allocator: std.mem.Allocator) !*VM {
    var vm = try allocator.create(VM);
    vm.allocator = allocator;
    vm.stackSize = 0;
    vm.firstObject = null;
    vm.stack = try std.ArrayList(*Object).initCapacity(allocator, STACK_MAX);
    vm.numObjects = 0;
    vm.maxObjects = INITIAL_GC_THRESHOLD;
    return vm;
}

const ObjectType = enum {
    OBJ_INT,
    OBJ_PAIR,
};

const ObjectUnion = union(ObjectType) {
    OBJ_INT: i32,
    OBJ_PAIR: struct {
        head: *Object,
        tail: *Object,
    },
};

const Object = struct {
    marked: bool = false,
    type: ObjectType,
    value: ObjectUnion,

    // we implement a linked list of objects so we can reach them through
    // this even if the are actually unreachable to the language user
    next: ?*Object,

    fn mark(self: *Object) void {
        if (self.marked) return;
        self.marked = true;
        if (self.type == ObjectType.OBJ_PAIR) {
            self.value.OBJ_PAIR.head.mark();
            self.value.OBJ_PAIR.tail.mark();
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try test1(allocator);
    try test2(allocator);
    try test3(allocator);
    try test4(allocator);
    try performance(allocator);
}

fn freeVM(vm: *VM) void {
    vm.stackSize = 0;
    vm.sweep(); // no need to mark, we are freeing everything just to end the program

    vm.stack.deinit();
    vm.allocator.destroy(vm);
}

fn assert(condition: bool, message: []const u8) void {
    if (!condition) {
        std.debug.print("Assertion failed: {s}\n", .{message});
        std.process.exit(1);
    }
}

fn test1(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 1: Objects on stack are preserved.\n", .{});
    const vm = try newVM(allocator);

    _ = try vm.pushInt(1);
    _ = try vm.pushInt(2);

    vm.gc();
    assert(vm.numObjects == 2, "Should have preserved objects.");

    freeVM(vm);
    std.debug.print("\n", .{});
}

fn test2(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 2: Unreached objects are collected.\n", .{});
    const vm = try newVM(allocator);

    _ = try vm.pushInt(1);
    _ = try vm.pushInt(2);
    _ = try vm.pop();
    _ = try vm.pop();

    vm.gc();
    assert(vm.numObjects == 0, "Should have collected objects.");

    vm.stack.deinit();
    allocator.destroy(vm);

    std.debug.print("\n", .{});
}

fn test3(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 3: Reach nested objects.\n", .{});
    const vm = try newVM(allocator);

    _ = try vm.pushInt(1);
    _ = try vm.pushInt(2);
    _ = try vm.pushPair();
    _ = try vm.pushInt(3);
    _ = try vm.pushInt(4);
    _ = try vm.pushPair();
    _ = try vm.pushPair();

    vm.gc();
    assert(vm.numObjects == 7, "Should have reached objects.");
    freeVM(vm);
    std.debug.print("\n", .{});
}

fn test4(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 4: Handle cycles.\n", .{});
    const vm = try newVM(allocator);
    defer allocator.destroy(vm);

    _ = try vm.pushInt(1);
    const y = try vm.pushInt(2);
    const a = try vm.pushPair();
    _ = try vm.pushInt(3);
    const x = try vm.pushInt(4);
    const b = try vm.pushPair();

    a.value.OBJ_PAIR.tail = b;
    b.value.OBJ_PAIR.tail = a;

    vm.gc();
    assert(vm.numObjects == 4, "Should have collected objects.");

    allocator.destroy(y);
    allocator.destroy(a);
    allocator.destroy(x);
    allocator.destroy(b);

    vm.stack.deinit();

    std.debug.print("\n", .{});
}

fn performance(allocator: std.mem.Allocator) !void {
    std.debug.print("Performance Test.\n", .{});
    const vm = try newVM(allocator);

    for (0..1000) |i| {
        for (0..20) |_| {
            _ = try vm.pushInt(@intCast(i));
        }

        for (0..20) |_| {
            _ = try vm.pop();
        }
    }

    freeVM(vm);
}
