// Imports ---------------------------------------------------------------------

const std = @import("std");

// Use zig translate-c to generate raylib.zig and swap imports to get better completion in IDEs

// const c = @import("raylib.zig");

const c = @cImport(
    @cInclude("raylib.h"),
);

// Wrappers / Convenience Functions --------------------------------------------

fn rect(x: f32, y: f32, width: f32, height: f32) c.Rectangle {
    return .{ .x = x, .y = y, .width = width, .height = height };
}

fn vec2(x: f32, y: f32) c.Vector2 {
    return c.Vector2{ .x = x, .y = y };
}

// Constants -------------------------------------------------------------------

const screen_width = 800;
const screen_height = 600;
/// Limits how wide of an angle the ball can bounce off a paddle with
/// Must be between 0 and 1
const bounce_angle_limit = 0.7;

// Keys
const player1_up_key = c.KEY_Q;
const player1_down_key = c.KEY_A;
const player2_up_key = c.KEY_P;
const player2_down_key = c.KEY_L;

const start_key = c.KEY_SPACE;
const pause_key = c.KEY_TAB;
const reset_key = c.KEY_R;

// Text
const title_text = "PONG";
const window_title = "PONG";
const start_message = "Press Space to Start.";
const paused_text = "Paused.";


// Types -----------------------------------------------------------------------

const GameState = enum {
    /// Right after launch or reset
    title,
    playing,
    pause,
    /// in-game after a player has scored
    start,
};

const Player = struct {
    rect: c.Rectangle,
    score: i32,

    /// Pixels
    const height = 40;
    /// Pixels
    const width = 5;
    /// Pixels per second
    const speed = 300;

    /// Move up or down clamped to screen size
    fn move(self: *Player, amt: f32) void {
        const new_y = self.rect.y + amt;
        if (new_y < 0 or new_y + Player.height > screen_height)
            return;

        self.rect.y = new_y;
    }
};

const Ball = struct {
    rect: c.Rectangle,
    velocity: c.Vector2,
    /// Pixels per second
    const speed = 500;

    /// Side length of square in pixels
    const size = 10;
};

const BallEvent = enum {
    bounce_top,
    bounce_bot,
    /// Bounced off player 1's paddle
    bounce1,
    /// Bounced off player 2's paddle
    bounce2,
    /// Scored a point for player 1
    score1,
    /// Scored a point for player 2
    score2,
};

// State -----------------------------------------------------------------------

var state: GameState = undefined;
/// Left Paddle
var player1: Player = undefined;
/// Right Paddle
var player2: Player = undefined;
var ball: Ball = undefined;

/// Shared buffer for String representations of each score
/// Raylib converts the string immediately and does not store the pointer
var score_str_buf: [32]u8 = undefined;

// Functions -------------------------------------------------------------------

pub fn main() !void {
    c.SetWindowState(c.FLAG_VSYNC_HINT);
    c.InitWindow(screen_width, screen_height, window_title);
    c.HideCursor();

    reset();

    while (!c.WindowShouldClose()) {
        update();
        draw();
    }
}

fn resetPlayerPos() void {
    const start_y = screen_height / 2 - Player.height / 2;
    player1.rect = rect(20, start_y, Player.width, Player.height);
    player2.rect = rect(screen_width - 20, start_y, Player.width, Player.height);
}

fn resetBall() void {
    const ball_y = screen_height / 2 - Ball.size / 2;
    ball = .{
        .rect = rect(screen_width / 2, ball_y, Ball.size, Ball.size),
        .velocity = vec2(-Ball.speed, 0),
    };
}

fn reset() void {
    state = .title;
    player1.score = 0;
    player2.score = 0;
    resetPlayerPos();
    resetBall();
}

fn update() void {
    // Reset
    if (c.IsKeyPressed(reset_key)) {
        reset();
        return;
    }

    switch (state) {
        .playing => {
            const delta = c.GetFrameTime();

            // Pause
            if (c.IsKeyPressed(pause_key)) {
                state = .pause;
                return;
            }

            // Player movement
            const move_amt = Player.speed * delta;
            if (c.IsKeyDown(player1_up_key))
                player1.move(-move_amt);
            if (c.IsKeyDown(player1_down_key))
                player1.move(move_amt);
            if (c.IsKeyDown(player2_up_key))
                player2.move(-move_amt);
            if (c.IsKeyDown(player2_down_key))
                player2.move(move_amt);

            // Update ball
            // Multiple events can happen in a single frame
            var time_left = delta;
            while (updateBall(&time_left)) |event| {
                switch (event) {
                    .score1 => {
                        player1.score += 1;
                        state = .start;
                        resetPlayerPos();
                        break;
                    },
                    .score2 => {
                        player2.score += 1;
                        state = .start;
                        resetPlayerPos();
                        break;
                    },
                    else => {},
                }
            }
        },
        .title, .start => {
            if (c.IsKeyPressed(start_key)) {
                resetPlayerPos();
                resetBall();
                state = .playing;
            }
        },
        .pause => {
            if (c.IsKeyPressed(pause_key)) {
                state = .playing;
            }
        },
    }
}

/// Check for all events that the ball could reach
/// and update the ball's state to after that event
/// subtract the time consumed from `time`
/// Last, return the event that occurred or null if no events occurred
fn updateBall(time: *f32) ?BallEvent {
    const player_time = playerTime();
    const wall_time = wallTime();
    const score_time = scoreTime();

    // Process the first event to occur
    const min_time = std.math.min3(player_time, wall_time, score_time);

    // No events occur in time
    // Just advance the ball
    if (min_time > time.*) {
        ball.rect.x += ball.velocity.x * time.*;
        ball.rect.y += ball.velocity.y * time.*;
        time.* = 0;
        return null;
    }

    // Subtract time and process event
    time.* -= min_time;

    if (min_time == score_time) {
        if (ball.velocity.x > 0) {
            return .score1;
        } else {
            return .score2;
        }
    } else if (min_time == wall_time) {
        return bounceWall(wall_time);
    } else if (min_time == player_time) {
        return bouncePaddle(player_time);
    } else {
        unreachable;
    }
}

/// Time before the ball reaches a player's paddle
/// or infinity if the ball will not reach a paddle
fn playerTime() f32 {
    const inf = std.math.inf(f32);
    const xv = ball.velocity.x;
    std.debug.assert(xv != 0);

    if (xv > 0) {
        // Handle player 2 case
        const xdist = player2.rect.x - Ball.size - ball.rect.x;
        if (xdist < 0) return inf;
        const ptime = xdist / xv;

        // Ensure that the ball does not miss the paddle
        const ypos = ball.rect.y + ball.velocity.y * ptime;
        if (ypos + Ball.size < player2.rect.y or ypos > player2.rect.y + Player.height)
            return inf;

        return ptime;
    } else {
        // Handle player 1 case
        const xdist = ball.rect.x - player1.rect.x - Player.width;
        if (xdist < 0) return inf;
        const ptime = xdist / -xv;

        // Ensure that the ball does not miss the paddle
        const ypos = ball.rect.y + ball.velocity.y * ptime;
        if (ypos + Ball.size < player1.rect.y or ypos > player1.rect.y + Player.height)
            return inf;

        return ptime;
    }
}

/// Time before the ball reaches the top or bottom edge
/// or infinity if the ball's y-velocity is zero
fn wallTime() f32 {
    const inf = std.math.inf(f32);
    const yv = ball.velocity.y;
    if (yv > 0) {
        const ydist = screen_height - Ball.size - ball.rect.y;
        return ydist / yv;
    } else if (yv < 0) {
        return ball.rect.y / -yv;
    } else {
        return inf;
    }
}

/// Time before the ball reaches the left or right edge
fn scoreTime() f32 {
    const xv = ball.velocity.x;
    if (xv > 0) {
        const xdist = screen_width - Ball.size - ball.rect.x;
        return xdist / xv;
    } else if (xv < 0) {
        const xdist = ball.rect.x;
        return xdist / -xv;
    } else {
        unreachable;
    }
}

/// Update the ball's state from bouncing off the top or bottom edge
/// and return the event (which edge)
fn bounceWall(time: f32) BallEvent {
    const xv = ball.velocity.x;
    const yv = ball.velocity.y;

    ball.rect.x += xv * time;
    ball.rect.y += yv * time;

    if (yv > 0) {
        ball.velocity.y *= -1;
        return .bounce_top;
    } else {
        ball.velocity.y *= -1;
        return .bounce_bot;
    }
}

/// Update the ball's state from bouncing off a paddle
/// and return the event (which player's paddle it bounced off)
fn bouncePaddle(time: f32) BallEvent {
    const y = ball.rect.y + ball.velocity.y * time;
    const xv = ball.velocity.x;
    std.debug.assert(xv != 0);

    var paddle_y: f32 = undefined;
    var ret: BallEvent = undefined;

    if (xv > 0) {
        paddle_y = player2.rect.y;
        ret = .bounce2;
    } else {
        paddle_y = player1.rect.y;
        ret = .bounce1;
    }

    const vel = paddleHitVelocity(y - paddle_y);
    ball.velocity.x = if (ret == .bounce1) vel.x else -vel.x;
    ball.velocity.y = vel.y;
    return ret;
}

/// New velocity of the ball
/// where `diff` is the ball's y-position minus the paddle's y-position
/// Always returns positive x velocity
fn paddleHitVelocity(diff: f32) c.Vector2 {
    // offset from the middle of the paddle
    const off = diff + Ball.size / 2 - Player.height / 2;
    // normalize it to a value within -1 and 1
    const norm_off = off / (Ball.size / 2 + Player.height / 2);
    const angle = norm_off * std.math.pi * 0.5 * bounce_angle_limit;

    return vec2(Ball.speed * @cos(angle), Ball.speed * @sin(angle));
}

fn draw() void {
    c.BeginDrawing();
    c.ClearBackground(c.BLACK);
    defer c.EndDrawing();

    // c.DrawFPS(80, 20);

    // Draw Scores
    c.DrawText(scoreStr(player1.score), 30, 30, 20, c.WHITE);
    const score2_text = scoreStr(player2.score);
    const score2_width = c.MeasureText(score2_text, 20);
    const score2_x = screen_width - 30 - score2_width;
    c.DrawText(score2_text, score2_x, 30, 20, c.WHITE);

    // Draw Players
    c.DrawRectangleRec(player1.rect, c.WHITE);
    c.DrawRectangleRec(player2.rect, c.WHITE);

    // Draw Other
    switch (state) {
        .playing => c.DrawRectangleRec(ball.rect, c.WHITE),
        .pause => {
            c.DrawRectangleRec(ball.rect, c.WHITE);
            drawCenterText(paused_text);
        },
        .start => {
            drawCenterText(start_message);
        },
        .title => {
            drawCenterText(start_message);

            const width = c.MeasureText(title_text, 100);
            const x = @divTrunc(screen_width, 2) - @divTrunc(width, 2);
            c.DrawText(title_text, x, screen_height / 4 - 50, 100, c.WHITE);
        },
    }
}

fn drawCenterText(text: [*c]const u8) void {
    const width = c.MeasureText(text, 20);
    const x = @divTrunc(screen_width, 2) - @divTrunc(width, 2);
    c.DrawText(text, x, screen_height / 2 - 10, 20, c.WHITE);
}

/// Get a C-style string from a score
fn scoreStr(score: i32) [*c]const u8 {
    // Just in case the buffer would _somehow_ overflow
    const buf = score_str_buf[0 .. score_str_buf.len - 1];
    const slice = std.fmt.bufPrint(buf, "{}", .{score}) catch {
        const text: [*c]const u8 = "error";
        return text;
    };
    score_str_buf[slice.len] = 0;
    return @ptrCast([*c]const u8, slice);
}
