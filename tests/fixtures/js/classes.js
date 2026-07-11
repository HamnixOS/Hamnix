class Animal {
  constructor(name){ this.name = name; }
  speak(){ return this.name + " makes a sound"; }
}
var a = new Animal("Rex");
console.log(a.speak());
console.log(a instanceof Animal);

class Dog extends Animal {
  constructor(name, breed){ super(name); this.breed = breed; }
  speak(){ return super.speak() + " (woof)"; }
  info(){ return this.name + " is a " + this.breed; }
}
var d = new Dog("Fido", "Lab");
console.log(d.speak());
console.log(d.info());
console.log(d instanceof Dog, d instanceof Animal, a instanceof Dog);

class Counter {
  constructor(){ this.n = 0; }
  inc(){ this.n++; return this; }
  value(){ return this.n; }
}
console.log(new Counter().inc().inc().inc().value());

class MathUtil {
  static square(x){ return x * x; }
  static cube(x){ return x * x * x; }
}
console.log(MathUtil.square(5), MathUtil.cube(3));

class Base { greet(){ return "base"; } }
class Mid extends Base { greet(){ return "mid+" + super.greet(); } }
class Top extends Mid { greet(){ return "top+" + super.greet(); } }
console.log(new Top().greet());

class Shape { constructor(n){ this.sides = n; } describe(){ return "shape with " + this.sides + " sides"; } }
class Square extends Shape { }
var sq = new Square(4);
console.log(sq.describe(), sq instanceof Shape);

var Point = class { constructor(x, y){ this.x = x; this.y = y; } sum(){ return this.x + this.y; } };
console.log(new Point(3, 4).sum());

var e = new TypeError("nope");
console.log(e instanceof TypeError, e instanceof Error, e.message);
