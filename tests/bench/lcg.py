def main():
    x = 1
    N = 50000000
    M = (1 << 64) - 1
    for _ in range(N):
        x = (x * 6364136223846793005 + 1442695040888963407) & M
    print(x)
main()
