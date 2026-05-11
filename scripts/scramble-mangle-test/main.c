/* main.c — calls compute() from libthing.o. Exits with compute(21) = 42. */
extern int compute(int x);

int main(void) {
    return compute(21);
}
