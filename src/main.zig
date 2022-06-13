const std = @import("std");

const sdl = @cImport({
    @cInclude("SDL.h");
});

pub const DecoderError = error{
    UnsupportedInstruction,
};

pub const EmulatorError = error{
    ProgramCounterOverflow,
};

pub fn main() anyerror!void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpalloc.deinit());
    const allocator = gpalloc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("Usage: {s} ROM_FILE", .{args[0]});
        return;
    }
    const rom_path = args[1];

    std.log.info("Initializing", .{});

    var rnd = std.rand.DefaultPrng.init(0);

    _ = sdl.SDL_Init(sdl.SDL_INIT_VIDEO);
    defer sdl.SDL_Quit();

    var window = sdl.SDL_CreateWindow("CHIP-8", sdl.SDL_WINDOWPOS_CENTERED, sdl.SDL_WINDOWPOS_CENTERED, 640, 320, 0);
    defer sdl.SDL_DestroyWindow(window);

    var renderer = sdl.SDL_CreateRenderer(window, 0, sdl.SDL_RENDERER_PRESENTVSYNC);
    defer sdl.SDL_DestroyRenderer(renderer);

    // Set logical size and let SDL handle scaling
    _ = sdl.SDL_RenderSetLogicalSize(renderer, 64, 32);

    // Create a texture with the same dimensions as our logical size
    // We use RGB332 since we want to use only one byte per pixel for easier indexing
    // (One bit per pixel would have been enough, but this is fine)
    var texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGB332, sdl.SDL_TEXTUREACCESS_STREAMING, 64, 32);

    // Raw pixels that we will be manipulating and then copying to the texture
    var pixels: [32*64]u8 = std.mem.zeroes([32*64]u8);

    // Emulator state
    var memory: [4096]u8 = std.mem.zeroes([4096]u8);
    var pc: u16 = 0x200;
    var regs: [16]u8 = [_]u8{0} ** 16;
    var stack: [64]u16 = [_]u16{0} ** 64;
    var sp: u6 = 0;
    var index: u16 = 0;
    var delay_timer: u8 = 0;
    var sound_timer: u8 = 0;
    var keys: [16]bool = [_]bool{false} ** 16;

    // Load font
    const font: [0x50]u8 = [_]u8 {
        0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
        0x20, 0x60, 0x20, 0x20, 0x70, // 1
        0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
        0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
        0x90, 0x90, 0xF0, 0x10, 0x10, // 4
        0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
        0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
        0xF0, 0x10, 0x20, 0x40, 0x40, // 7
        0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
        0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
        0xF0, 0x90, 0xF0, 0x90, 0x90, // A
        0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
        0xF0, 0x80, 0x80, 0x80, 0xF0, // C
        0xE0, 0x90, 0x90, 0x90, 0xE0, // D
        0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
        0xF0, 0x80, 0xF0, 0x80, 0x80  // F
    };
    std.mem.copy(u8, memory[0x50..], font[0..]);

    // Load program
    const file = try std.fs.cwd().openFile(rom_path, .{ .read = true });
    defer file.close();
    _ = try file.readAll(memory[0x200..]);

    // Draw at least once
    var draw: bool = true;
    @memset(pixels[0..], 0, 32*64);

    var infinite_loop: bool = false;

    var ticks = sdl.SDL_GetTicks();

    mainloop: while (true) {
        // Handle SDL events
        var sdl_event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&sdl_event) != 0) {
            switch (sdl_event.type) {
                sdl.SDL_QUIT => break :mainloop,
                sdl.SDL_KEYDOWN, sdl.SDL_KEYUP => {
                    var keystate: bool = (sdl_event.type == sdl.SDL_KEYDOWN);
                    switch (sdl_event.key.keysym.scancode) {
                        sdl.SDL_SCANCODE_ESCAPE => break :mainloop,

                        sdl.SDL_SCANCODE_1 => keys[0x1] = keystate,
                        sdl.SDL_SCANCODE_2 => keys[0x2] = keystate,
                        sdl.SDL_SCANCODE_3 => keys[0x3] = keystate,
                        sdl.SDL_SCANCODE_4 => keys[0xc] = keystate,
                        sdl.SDL_SCANCODE_Q => keys[0x4] = keystate,
                        sdl.SDL_SCANCODE_W => keys[0x5] = keystate,
                        sdl.SDL_SCANCODE_E => keys[0x6] = keystate,
                        sdl.SDL_SCANCODE_R => keys[0xd] = keystate,
                        sdl.SDL_SCANCODE_A => keys[0x7] = keystate,
                        sdl.SDL_SCANCODE_S => keys[0x8] = keystate,
                        sdl.SDL_SCANCODE_D => keys[0x9] = keystate,
                        sdl.SDL_SCANCODE_F => keys[0xe] = keystate,
                        sdl.SDL_SCANCODE_Z => keys[0xa] = keystate,
                        sdl.SDL_SCANCODE_X => keys[0x0] = keystate,
                        sdl.SDL_SCANCODE_C => keys[0xb] = keystate,
                        sdl.SDL_SCANCODE_V => keys[0xf] = keystate,

                        else => {},
                    }
                },
                else => {},
            }
        }

        if (infinite_loop) continue :mainloop;

        // Timers
        var current_ticks = sdl.SDL_GetTicks();
        if (current_ticks - ticks > 60) {
            if (delay_timer > 0) delay_timer -= 1;
            if (sound_timer > 0) sound_timer -= 1;
            ticks = current_ticks;
        }

        // Fetch instruction
        var inst: u16 = @intCast(u16, memory[pc]) << 8 | @intCast(u16, memory[pc+1]);
        //std.log.debug("pc = {x}, inst = {x}", .{ pc, inst });
        pc += 2;
        if (pc >= 0xfff) {
            return error.ProgramCounterOverflow;
        }

        // Decode and execute
        var x: u4 = @truncate(u4, inst >> 8);
        var y: u4 = @truncate(u4, inst >> 4);
        var nnn: u12 = @truncate(u12, inst);
        var nn: u8 = @truncate(u8, inst);
        var n: u4 = @truncate(u4, inst);
        switch (inst >> 12) {
            0x0 => {
                switch (nnn) {
                    0x0e0 => {
                        // Clear display
                        @memset(pixels[0..], 0, 32*64);
                    },
                    0x0ee => {
                        // Return from subroutine
                        pc = stack[sp];
                        sp -= 1;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            0x1 => {
                // Jump to address
                if (pc-2 == nnn) {
                    std.log.debug("Infinite loop detected", .{});
                    infinite_loop = true;
                }
                pc = nnn;
            },
            0x2 => {
                // Call subroutine
                sp += 1;
                stack[sp] = pc;
                pc = nnn;
            },
            0x3 => {
                // Skip instruction if register is equal to value
                if (regs[x] == nn) {
                    pc += 2;
                }
            },
            0x4 => {
                // Skip instruction if register is not equal to value
                if (regs[x] != nn) {
                    pc += 2;
                }
            },
            0x5 => {
                if (n != 0) {
                    return error.UnsupportedInstruction;
                }
                // Skip instructions if register x is equal to register y
                if (regs[x] == regs[y]) {
                    pc += 2;
                }
            },
            0x6 => {
                // Store in register
                regs[x] = nn;
            },
            0x7 => {
                // Add to register
                regs[x] +%= nn; // Wrapping addition
            },
            0x8 => {
                switch (n) {
                    0x0 => {
                        // Store register y in register x
                        regs[x] = regs[y];
                    },
                    0x1 => {
                        // OR
                        regs[x] = regs[x] | regs[y];
                    },
                    0x2 => {
                        // AND
                        regs[x] = regs[x] & regs[y];
                    },
                    0x3 => {
                        // XOR
                        regs[x] = regs[x] ^ regs[y];
                    },
                    0x4 => {
                        // Add register y to register x
                        var res: u8 = 0;
                        var overflow = @addWithOverflow(u8, regs[x], regs[y], &res);
                        if (overflow) {
                            regs[0xf] = 0x00;
                        } else {
                            regs[0xf] = 0x01;
                        }
                        regs[x] = res;
                    },
                    0x5 => {
                        // Subtract register y from register x
                        var res: u8 = 0;
                        var underflow = @subWithOverflow(u8, regs[x], regs[y], &res);
                        if (underflow) {
                            regs[0xf] = 0x00;
                        } else {
                            regs[0xf] = 0x01;
                        }
                        regs[x] = res;
                    },
                    0x6 => {
                        // Shift register y to the right and store in register x
                        // TODO: Alternative/quirk implementation: Use x instead of y
                        var lsb: u1 = @truncate(u1, regs[x]);
                        regs[0xf] = lsb;
                        regs[x] = regs[x] >> 1;
                    },
                    0x7 => {
                        // Subtract register x from register y and store in register x
                        var res: u8 = 0;
                        var underflow = @subWithOverflow(u8, regs[y], regs[x], &res);
                        if (underflow) {
                            regs[0xf] = 0x00;
                        } else {
                            regs[0xf] = 0x01;
                        }
                        regs[x] = res;
                    },
                    0xe => {
                        // Shift register y to the left and store in register x
                        // TODO: Alternative implementation: Use x instead of y
                        var msb: u1 = @truncate(u1, regs[x] >> 7);
                        regs[0xf] = msb;
                        regs[x] = regs[x] << 1;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            0x9 => {
                if (n != 0) {
                    return error.UnsupportedInstruction;
                }
                // Skip instructions if register x is not equal to register y
                if (regs[x] != regs[y]) {
                    pc += 2;
                }
            },
            0xa => {
                // Store memory address in index
                index = nnn;
            },
            0xb => {
                // Jump to address plus register 0
                pc = nnn + regs[0x0];
            },
            0xc => {
                // Set register x to a random number with mask
                regs[x] = rnd.random().int(u8) & nn;
            },
            0xd => {
                // Draw sprite
                regs[0xf] = 0x00;
                var j: usize = 0;
                draw_sprite_y: while (j < n) {
                    var y_coord = (regs[y] & 31) + j;
                    if (y_coord > 31) break :draw_sprite_y;
                    var data = memory[index + j];
                    var k: usize = 0;
                    draw_sprite_x: while (k < 8) {
                        var x_coord = (regs[x] & 63) + k;
                        if (x_coord > 63) break :draw_sprite_x;
                        var offset = y_coord * 64 + x_coord;
                        if (@truncate(u1, data >> @truncate(u3, 7-k)) != 0) {
                            if (pixels[offset] != 0) {
                                regs[0xf] = 0x01;
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
                        if (keys[regs[x]]) pc += 2;
                    },
                    0xa1 => {
                        // Skip if key is not pressed
                        if (!keys[regs[x]]) pc += 2;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            0xf => {
                switch (nn) {
                    0x07 => {
                        // Store delay timer in register x
                        regs[x] = delay_timer;
                    },
                    0x0a => {
                        // Wait for keypress
                        var found: bool = false;
                        var i: u8 = 0;
                        while (i <= 0xf) {
                            if (keys[i]) {
                                regs[x] = i;
                                found = true;
                                break;
                            }
                            i += 1;
                        }
                        if (!found) pc -= 2;
                    },
                    0x15 => {
                        // Set delay timer to register x
                        delay_timer = regs[x];
                    },
                    0x18 => {
                        // Set sound timer to register x
                        sound_timer = regs[x];
                    },
                    0x1e => {
                        // Add register x to index
                        index += regs[x];
                    },
                    0x29 => {
                        // Set index to address of sprite for hex digit in register x
                        index = 0x50 + regs[x] * 5;
                    },
                    0x33 => {
                        // Store BCD equivalent of register x in index, index + 1 and index + 2
                        memory[index] = regs[x] / 100;
                        memory[index + 1] = (regs[x] % 100) / 10;
                        memory[index + 2] = regs[x] % 10;
                    },
                    0x55 => {
                        var i: u8 = 0;
                        while (i <= x) {
                            memory[index+i] = regs[i];
                            i += 1;
                        }
                        // TODO: Alternative implementation: Increment index
                        //index += i;
                    },
                    0x65 => {
                        var i: u8 = 0;
                        while (i <= x) {
                            regs[i] = memory[index+i];
                            i += 1;
                        }
                        // TODO: Alternative implentation: Increment index
                        //index += i;
                    },
                    else => return error.UnsupportedInstruction,
                }
            },
            else => return error.UnsupportedInstruction,
        }

        // Render graphics
        if (draw) {
            var pixelsPtr = @ptrCast(*anyopaque, &pixels);
            _ = sdl.SDL_UpdateTexture(texture, 0, pixelsPtr, 64);
            _ = sdl.SDL_RenderCopy(renderer, texture, 0, 0);
            sdl.SDL_RenderPresent(renderer);

            draw = false;
        }
    }
}
