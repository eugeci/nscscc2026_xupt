#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define BOARD_W 32
#define BOARD_H 18
#define MAX_SNAKE (BOARD_W * BOARD_H)
#define TICK_US 150000

enum direction {
    DIR_UP,
    DIR_DOWN,
    DIR_LEFT,
    DIR_RIGHT
};

static struct termios saved_termios;
static int termios_saved;
static volatile sig_atomic_t stop_requested;

static int snake_x[MAX_SNAKE];
static int snake_y[MAX_SNAKE];
static int snake_length;
static int food_x;
static int food_y;
static int score;
static enum direction current_direction;
static unsigned int random_state;

static void request_stop(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static void restore_terminal(void)
{
    if (termios_saved)
        tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
}

static int configure_terminal(void)
{
    struct termios terminal;

    if (!isatty(STDIN_FILENO)) {
        fprintf(stderr, "snake: stdin is not a terminal\n");
        return -1;
    }

    if (tcgetattr(STDIN_FILENO, &saved_termios) != 0) {
        perror("snake: tcgetattr");
        return -1;
    }
    termios_saved = 1;

    terminal = saved_termios;
    terminal.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    terminal.c_iflag &= (tcflag_t)~(IXON | ICRNL);
    terminal.c_cc[VMIN] = 0;
    terminal.c_cc[VTIME] = 0;

    if (tcsetattr(STDIN_FILENO, TCSANOW, &terminal) != 0) {
        perror("snake: tcsetattr");
        termios_saved = 0;
        return -1;
    }

    return 0;
}

static unsigned int next_random(void)
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}

static int snake_contains(int x, int y, int count)
{
    int i;

    for (i = 0; i < count; ++i) {
        if (snake_x[i] == x && snake_y[i] == y)
            return 1;
    }
    return 0;
}

static void place_food(void)
{
    int attempts;

    for (attempts = 0; attempts < MAX_SNAKE * 2; ++attempts) {
        int x = 1 + (int)(next_random() % (BOARD_W - 2));
        int y = 1 + (int)(next_random() % (BOARD_H - 2));

        if (!snake_contains(x, y, snake_length)) {
            food_x = x;
            food_y = y;
            return;
        }
    }

    food_x = -1;
    food_y = -1;
}

static void initialize_game(void)
{
    int i;

    snake_length = 5;
    score = 0;
    current_direction = DIR_RIGHT;

    for (i = 0; i < snake_length; ++i) {
        snake_x[i] = BOARD_W / 2 - i;
        snake_y[i] = BOARD_H / 2;
    }

    place_food();
}

static void append_char(char *buffer, size_t capacity, size_t *used, char value)
{
    if (*used + 1 < capacity)
        buffer[(*used)++] = value;
}

static void append_text(char *buffer, size_t capacity, size_t *used,
                        const char *text)
{
    while (*text != '\0') {
        append_char(buffer, capacity, used, *text);
        ++text;
    }
}

static void draw_game(int first_frame, int paused)
{
    char output[2048];
    char status[128];
    size_t used = 0;
    int x;
    int y;

    if (first_frame)
        append_text(output, sizeof(output), &used, "\033[2J\033[H");
    else
        append_text(output, sizeof(output), &used, "\033[H");

    for (y = 0; y < BOARD_H; ++y) {
        for (x = 0; x < BOARD_W; ++x) {
            char cell = ' ';

            if (x == 0 || x == BOARD_W - 1 || y == 0 || y == BOARD_H - 1)
                cell = '#';
            else if (x == snake_x[0] && y == snake_y[0])
                cell = '@';
            else if (snake_contains(x, y, snake_length))
                cell = 'o';
            else if (x == food_x && y == food_y)
                cell = '*';

            append_char(output, sizeof(output), &used, cell);
        }
        append_text(output, sizeof(output), &used, "\r\n");
    }

    snprintf(status, sizeof(status),
             "Score: %-4d  W/A/S/D or arrows  P pause  Q quit\r\n",
             score);
    append_text(output, sizeof(output), &used, status);

    if (paused)
        append_text(output, sizeof(output), &used,
                    "PAUSED - press P to continue                    \r\n");
    else
        append_text(output, sizeof(output), &used,
                    "VisionArm FPGA SoC Snake                        \r\n");

    output[used] = '\0';
    fwrite(output, 1, used, stdout);
    fflush(stdout);
}

static int is_opposite(enum direction first, enum direction second)
{
    return (first == DIR_UP && second == DIR_DOWN) ||
           (first == DIR_DOWN && second == DIR_UP) ||
           (first == DIR_LEFT && second == DIR_RIGHT) ||
           (first == DIR_RIGHT && second == DIR_LEFT);
}

static int set_direction(enum direction requested)
{
    if (!is_opposite(current_direction, requested)) {
        current_direction = requested;
        return 1;
    }
    return 0;
}

static void process_input(int *paused)
{
    unsigned char input[32];
    ssize_t count;
    ssize_t i;
    int direction_changed = 0;

    do {
        count = read(STDIN_FILENO, input, sizeof(input));
        if (count < 0 && errno != EAGAIN && errno != EINTR) {
            stop_requested = 1;
            return;
        }

        for (i = 0; i < count; ++i) {
            unsigned char key = input[i];

            if (key == 'q' || key == 'Q' || key == 3) {
                stop_requested = 1;
            } else if (key == 'p' || key == 'P') {
                *paused = !*paused;
            } else if (!direction_changed && (key == 'w' || key == 'W')) {
                direction_changed = set_direction(DIR_UP);
            } else if (!direction_changed && (key == 's' || key == 'S')) {
                direction_changed = set_direction(DIR_DOWN);
            } else if (!direction_changed && (key == 'a' || key == 'A')) {
                direction_changed = set_direction(DIR_LEFT);
            } else if (!direction_changed && (key == 'd' || key == 'D')) {
                direction_changed = set_direction(DIR_RIGHT);
            } else if (!direction_changed && key == 0x1b &&
                       i + 2 < count && input[i + 1] == '[') {
                switch (input[i + 2]) {
                case 'A': direction_changed = set_direction(DIR_UP); break;
                case 'B': direction_changed = set_direction(DIR_DOWN); break;
                case 'C': direction_changed = set_direction(DIR_RIGHT); break;
                case 'D': direction_changed = set_direction(DIR_LEFT); break;
                default: break;
                }
                i += 2;
            }
        }
    } while (count > 0);
}

static int advance_snake(void)
{
    int new_x = snake_x[0];
    int new_y = snake_y[0];
    int grows;
    int collision_count;
    int i;

    switch (current_direction) {
    case DIR_UP:    --new_y; break;
    case DIR_DOWN:  ++new_y; break;
    case DIR_LEFT:  --new_x; break;
    case DIR_RIGHT: ++new_x; break;
    }

    if (new_x <= 0 || new_x >= BOARD_W - 1 ||
        new_y <= 0 || new_y >= BOARD_H - 1)
        return 0;

    grows = (new_x == food_x && new_y == food_y);
    collision_count = grows ? snake_length : snake_length - 1;
    if (snake_contains(new_x, new_y, collision_count))
        return 0;

    if (grows && snake_length < MAX_SNAKE)
        ++snake_length;

    for (i = snake_length - 1; i > 0; --i) {
        snake_x[i] = snake_x[i - 1];
        snake_y[i] = snake_y[i - 1];
    }
    snake_x[0] = new_x;
    snake_y[0] = new_y;

    if (grows) {
        ++score;
        place_food();
    }

    return 1;
}

int main(void)
{
    int alive = 1;
    int paused = 0;
    int first_frame = 1;

    random_state = (unsigned int)time(NULL) ^
                   (unsigned int)getpid() ^ 0x5641524dU;
    if (random_state == 0)
        random_state = 0x13579bdfU;

    if (configure_terminal() != 0)
        return 1;

    atexit(restore_terminal);
    signal(SIGINT, request_stop);
    signal(SIGTERM, request_stop);
    signal(SIGHUP, request_stop);

    initialize_game();

    while (!stop_requested && alive) {
        draw_game(first_frame, paused);
        first_frame = 0;
        usleep(TICK_US);
        process_input(&paused);
        if (!paused && !stop_requested)
            alive = advance_snake();
    }

    restore_terminal();
    termios_saved = 0;
    printf("\033[H\033[2J");
    if (alive)
        printf("Snake exited. Final score: %d\r\n", score);
    else
        printf("Game over. Final score: %d\r\n", score);
    fflush(stdout);

    return alive ? 0 : 1;
}
