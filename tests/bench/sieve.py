def main():
    N = 5000000
    flags = bytearray(N + 1)
    i = 2
    while i * i <= N:
        if flags[i] == 0:
            j = i * i
            while j <= N:
                flags[j] = 1
                j += i
        i += 1
    count = 0
    i = 2
    while i <= N:
        if flags[i] == 0:
            count += 1
        i += 1
    print(count)
main()
