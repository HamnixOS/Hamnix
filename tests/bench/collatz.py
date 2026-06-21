def collatz_steps(n):
    steps = 0
    while n != 1:
        if (n & 1) == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        steps += 1
    return steps


def main():
    N = 1000000
    total = 0
    for i in range(1, N + 1):
        total += collatz_steps(i)
    print(total)


main()
