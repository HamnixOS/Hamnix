def main():
    DIM = 300
    A = [0] * (DIM * DIM)
    B = [0] * (DIM * DIM)
    C = [0] * (DIM * DIM)
    for i in range(DIM):
        for j in range(DIM):
            A[i * DIM + j] = (i + j) % 7
            B[i * DIM + j] = (i * 2 + j) % 7
    for i in range(DIM):
        for j in range(DIM):
            s = 0
            for k in range(DIM):
                s += A[i * DIM + k] * B[k * DIM + j]
            C[i * DIM + j] = s
    print(sum(C))
main()
