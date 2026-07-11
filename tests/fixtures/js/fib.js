function fib(n){ if (n < 2){ return n; } return fib(n - 1) + fib(n - 2); }
console.log(fib(10), fib(15), fib(20));
function fact(n){ if (n <= 1){ return 1; } return n * fact(n - 1); }
console.log(fact(5), fact(10));
console.log(Math.sqrt(144), Math.pow(2, 10), Math.abs(-7), Math.max(1,9,4), Math.min(3,1,8));
console.log(Math.floor(3.9), Math.ceil(3.1), Math.round(3.5));
console.log(typeof 5, typeof "x", typeof true, typeof undefined, typeof null, typeof [], typeof {});
console.log(parseInt("100"), parseFloat("3.14"), isNaN(0/0));
