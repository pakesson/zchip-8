const std = @import("std");

const sdl = @cImport({
    @cInclude("SDL.h");
});

const Const = struct {
    const MEMORY_SIZE: usize = 4096;
    const NUM_REGISTERS: usize = 16;
    const STACK_SIZE: usize = 64;
    const NUM_KEYS: usize = 16;
    const PROGRAM_START: u16 = 0x200;
    const FONT_LENGTH: u16 = 0x50;
    const FONT_START: u16 = 0x50;
    const FONT_END: u16 = 0xa0;
};

pub const DecoderError = error{
    UnsupportedInstruction,
};

pub const EmulatorError = error{
    ProgramCounterOverflow,
};

const FONT: [Const.FONT_LENGTH]u8 = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

const EmulatorState = struct {
    memory: [Const.MEMORY_SIZE]u8,
    pc: u16,
    regs: [Const.NUM_REGISTERS]u8,
    stack: [Const.STACK_SIZE]u16,
    sp: u6,
    index: u16,
    delay_timer: u8,
    sound_timer: u8,
    keys: [Const.NUM_KEYS]bool,

    pub fn init() EmulatorState {
        var state = EmulatorState{
            .memory = std.mem.zeroes([Const.MEMORY_SIZE]u8),
            .pc = Const.PROGRAM_START,
            .regs = [_]u8{0} ** Const.NUM_REGISTERS,
            .stack = [_]u16{0} ** Const.STACK_SIZE,
            .sp = 0,
            .index = 0,
            .delay_timer = 0,
            .sound_timer = 0,
            .keys = [_]bool{false} ** Const.NUM_KEYS,
        };

        // Load font data into memory
        @memcpy(state.memory[Const.FONT_START..Const.FONT_END], FONT[0..]);
        return state;
    }
};

fn handle_sdl_events(state: *EmulatorState) bool {
    var sdl_event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&sdl_event) != 0) {
        switch (sdl_event.type) {
            sdl.SDL_QUIT => return false,
            sdl.SDL_KEYDOWN, sdl.SDL_KEYUP => {
                const keystate: bool = (sdl_event.type == sdl.SDL_KEYDOWN);
                switch (sdl_event.key.keysym.scancode) {
                    sdl.SDL_SCANCODE_ESCAPE => return false,

                    sdl.SDL_SCANCODE_1 => state.keys[0x1] = keystate,
                    sdl.SDL_SCANCODE_2 => state.keys[0x2] = keystate,
                    sdl.SDL_SCANCODE_3 => state.keys[0x3] = keystate,
                    sdl.SDL_SCANCODE_4 => state.keys[0xc] = keystate,
                    sdl.SDL_SCANCODE_Q => state.keys[0x4] = keystate,
                    sdl.SDL_SCANCODE_W => state.keys[0x5] = keystate,
                    sdl.SDL_SCANCODE_E => state.keys[0x6] = keystate,
                    sdl.SDL_SCANCODE_R => state.keys[0xd] = keystate,
                    sdl.SDL_SCANCODE_A => state.keys[0x7] = keystate,
                    sdl.SDL_SCANCODE_S => state.keys[0x8] = keystate,
                    sdl.SDL_SCANCODE_D => state.keys[0x9] = keystate,
                    sdl.SDL_SCANCODE_F => state.keys[0xe] = keystate,
                    sdl.SDL_SCANCODE_Z => state.keys[0xa] = keystate,
                    sdl.SDL_SCANCODE_X => state.keys[0x0] = keystate,
                    sdl.SDL_SCANCODE_C => state.keys[0xb] = keystate,
                    sdl.SDL_SCANCODE_V => state.keys[0xf] = keystate,

                    else => {},
                }
            },
            else => {},
        }
    }
    return true;
}

pub fn main() anyerror!void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpalloc.deinit() == .ok);
    const allocator = gpalloc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("Usage: {s} ROM_FILE\n", .{args[0]});
        return;
    }
    const rom_path = args[1];

    std.log.info("Initializing", .{});

    var rnd = std.rand.DefaultPrng.init(0);

    // Initialize emulator state
    var state = EmulatorState.init();

    // Load program
    std.log.info("Loading program", .{});
    const file = try std.fs.cwd().openFile(rom_path, .{ .mode = .read_only });
    defer file.close();
    _ = try file.readAll(state.memory[0x200..]);

    // Initialize SDL
    std.log.info("Initializing SDL", .{});
    _ = sdl.SDL_Init(sdl.SDL_INIT_VIDEO);
    defer sdl.SDL_Quit();

    std.log.info("Creating window", .{});
    const window = sdl.SDL_CreateWindow("CHIP-8", sdl.SDL_WINDOWPOS_CENTERED, sdl.SDL_WINDOWPOS_CENTERED, 640, 320, 0);
    defer sdl.SDL_DestroyWindow(window);

    std.log.info("Creating renderer", .{});
    const renderer = sdl.SDL_CreateRenderer(window, 0, sdl.SDL_RENDERER_PRESENTVSYNC);
    defer sdl.SDL_DestroyRenderer(renderer);

    // Set logical size and let SDL handle scaling
    _ = sdl.SDL_RenderSetLogicalSize(renderer, 64, 32);

    // Create a texture with the same dimensions as our logical size
    // We use RGB332 since we want to use only one byte per pixel for easier indexing
    // (One bit per pixel would have been enough, but this is fine)
    const texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGB332, sdl.SDL_TEXTUREACCESS_STREAMING, 64, 32);

    // Raw pixels that we will be manipulating and then copying to the texture
    var pixels: [32 * 64]u8 = std.mem.zeroes([32 * 64]u8);

    // Draw at least once
    var draw: bool = true;
    @memset(pixels[0..], 0);

    var infinite_loop: bool = false;

    var ticks = sdl.SDL_GetTicks();

    std.log.info("Starting main loop", .{});
    mainloop: while (true) {
        // Handle SDL events
        if (!handle_sdl_events(&state)) break :mainloop;

        if (infinite_loop) continue :mainloop;

        // Timers
        const current_ticks = sdl.SDL_GetTicks();
        if (current_ticks - ticks > 60) {
            if (state.delay_timer > 0) state.delay_timer -= 1;
            if (state.sound_timer > 0) state.sound_timer -= 1;
            ticks = current_ticks;
        }

        // Fetch instruction
        const inst: u16 = @as(u16, @intCast(state.memory[state.pc])) << 8 | @as(u16, @intCast(state.memory[state.pc + 1]));
        //std.log.debug("pc = {x}, inst = {x}", .{ state.pc, inst });
        state.pc += 2;
        if (state.pc >= 0xfff) {
            return error.ProgramCounterOverflow;
        }

        // Decode and execute
        const x: u4 = @truncate(inst >> 8);
        const y: u4 = @truncate(inst >> 4);
        const nnn: u12 = @truncate(inst);
        const nn: u8 = @truncate(inst);
        const n: u4 = @truncate(inst);
        switch (inst >> 12) {
            0x0 => {
                switch (nnn) {
                    0x0e0 => {
                        // Clear display
                        @memset(pixels[0..], 0);
                    },
                    0x0ee => {
                        // Return from subroutine
                        state.pc = state.stack[state.sp];
                        state.sp -= 1;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            0x1 => {
                // Jump to address
                if (state.pc - 2 == nnn) {
                    std.log.debug("Infinite loop detected", .{});
                    infinite_loop = true;
                }
                state.pc = nnn;
            },
            0x2 => {
                // Call subroutine
                state.sp += 1;
                state.stack[state.sp] = state.pc;
                state.pc = nnn;
            },
            0x3 => {
                // Skip instruction if register is equal to value
                if (state.regs[x] == nn) {
                    state.pc += 2;
                }
            },
            0x4 => {
                // Skip instruction if register is not equal to value
                if (state.regs[x] != nn) {
                    state.pc += 2;
                }
            },
            0x5 => {
                if (n != 0) {
                    return error.UnsupportedInstruction;
                }
                // Skip instructions if register x is equal to register y
                if (state.regs[x] == state.regs[y]) {
                    state.pc += 2;
                }
            },
            0x6 => {
                // Store in register
                state.regs[x] = nn;
            },
            0x7 => {
                // Add to register
                state.regs[x] +%= nn; // Wrapping addition
            },
            0x8 => {
                switch (n) {
                    0x0 => {
                        // Store register y in register x
                        state.regs[x] = state.regs[y];
                    },
                    0x1 => {
                        // OR
                        state.regs[x] = state.regs[x] | state.regs[y];
                    },
                    0x2 => {
                        // AND
                        state.regs[x] = state.regs[x] & state.regs[y];
                    },
                    0x3 => {
                        // XOR
                        state.regs[x] = state.regs[x] ^ state.regs[y];
                    },
                    0x4 => {
                        // Add register y to register x
                        const res = @addWithOverflow(state.regs[x], state.regs[y]);
                        if (res[1] != 0) {
                            state.regs[0xf] = 0x01;
                        } else {
                            state.regs[0xf] = 0x00;
                        }
                        state.regs[x] = res[0];
                    },
                    0x5 => {
                        // Subtract register y from register x
                        const res = @subWithOverflow(state.regs[x], state.regs[y]);
                        if (res[1] != 0) {
                            state.regs[0xf] = 0x00;
                        } else {
                            state.regs[0xf] = 0x01;
                        }
                        state.regs[x] = res[0];
                    },
                    0x6 => {
                        // Shift register y to the right and store in register x
                        // TODO: Alternative/quirk implementation: Use x instead of y
                        const lsb: u1 = @truncate(state.regs[x]);
                        state.regs[0xf] = lsb;
                        state.regs[x] = state.regs[x] >> 1;
                    },
                    0x7 => {
                        // Subtract register x from register y and store in register x
                        const res = @subWithOverflow(state.regs[y], state.regs[x]);
                        if (res[1] != 0) {
                            state.regs[0xf] = 0x00;
                        } else {
                            state.regs[0xf] = 0x01;
                        }
                        state.regs[x] = res[0];
                    },
                    0xe => {
                        // Shift register y to the left and store in register x
                        // TODO: Alternative implementation: Use x instead of y
                        const msb: u1 = @truncate(state.regs[x] >> 7);
                        state.regs[0xf] = msb;
                        state.regs[x] = state.regs[x] << 1;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            0x9 => {
                if (n != 0) {
                    return error.UnsupportedInstruction;
                }
                // Skip instructions if register x is not equal to register y
                if (state.regs[x] != state.regs[y]) {
                    state.pc += 2;
                }
            },
            0xa => {
                // Store memory address in index
                state.index = nnn;
            },
            0xb => {
                // Jump to address plus register 0
                state.pc = nnn + state.regs[0x0];
            },
            0xc => {
                // Set register x to a random number with mask
                state.regs[x] = rnd.random().int(u8) & nn;
            },
            0xd => {
                // Draw sprite
                state.regs[0xf] = 0x00;
                var j: usize = 0;
                draw_sprite_y: while (j < n) {
                    const y_coord = (state.regs[y] & 31) + j;
                    if (y_coord > 31) break :draw_sprite_y;
                    const data = state.memory[state.index + j];
                    var k: usize = 0;
                    draw_sprite_x: while (k < 8) {
                        const x_coord = (state.regs[x] & 63) + k;
                        if (x_coord > 63) break :draw_sprite_x;
                        const offset = y_coord * 64 + x_coord;
                        if (@as(u1, @truncate(data >> @as(u3, @truncate(7 - k)))) != 0) {
                            if (pixels[offset] != 0) {
                                state.regs[0xf] = 0x01;
                                pixels[offset] = 0;
                            } else {
                                pixels[offset] = 0xff;
                            }
                            draw = true;
                        }
                        k += 1;
                    }
                    j += 1;
                }
            },
            0xe => {
                switch (nn) {
                    0x9e => {
                        // Skip if key is pressed
                        if (state.keys[state.regs[x]]) state.pc += 2;
                    },
                    0xa1 => {
                        // Skip if key is not pressed
                        if (!state.keys[state.regs[x]]) state.pc += 2;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            0xf => {
                switch (nn) {
                    0x07 => {
                        // Store delay timer in register x
                        state.regs[x] = state.delay_timer;
                    },
                    0x0a => {
                        // Wait for keypress
                        var found: bool = false;
                        var i: u8 = 0;
                        while (i <= 0xf) {
                            if (state.keys[i]) {
                                state.regs[x] = i;
                                found = true;
                                break;
                            }
                            i += 1;
                        }
                        if (!found) state.pc -= 2;
                    },
                    0x15 => {
                        // Set delay timer to register x
                        state.delay_timer = state.regs[x];
                    },
                    0x18 => {
                        // Set sound timer to register x
                        state.sound_timer = state.regs[x];
                    },
                    0x1e => {
                        // Add register x to index
                        state.index += state.regs[x];
                    },
                    0x29 => {
                        // Set index to address of sprite for hex digit in register x
                        state.index = 0x50 + state.regs[x] * 5;
                    },
                    0x33 => {
                        // Store BCD equivalent of register x in index, index + 1 and index + 2
                        state.memory[state.index] = state.regs[x] / 100;
                        state.memory[state.index + 1] = (state.regs[x] % 100) / 10;
                        state.memory[state.index + 2] = state.regs[x] % 10;
                    },
                    0x55 => {
                        var i: u8 = 0;
                        while (i <= x) {
                            state.memory[state.index + i] = state.regs[i];
                            i += 1;
                        }
                        // TODO: Alternative implementation: Increment index
                        //state.index += i;
                    },
                    0x65 => {
                        var i: u8 = 0;
                        while (i <= x) {
                            state.regs[i] = state.memory[state.index + i];
                            i += 1;
                        }
                        // TODO: Alternative implentation: Increment index
                        //state.index += i;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            else => return error.UnsupportedInstruction,
        }

        // Render graphics
        if (draw) {
            const pixelsPtr: *anyopaque = @ptrCast(&pixels);
            _ = sdl.SDL_UpdateTexture(texture, 0, pixelsPtr, 64);
            _ = sdl.SDL_RenderCopy(renderer, texture, 0, 0);
            sdl.SDL_RenderPresent(renderer);

            draw = false;
        }
    }
}
