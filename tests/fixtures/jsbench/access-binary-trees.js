// SunSpider access-binary-trees: allocate/traverse binary trees (GC + recursion)
function TreeNode(left,right,item){this.left=left;this.right=right;this.item=item;}
TreeNode.prototype.itemCheck=function(){
  if(this.left==null) return this.item;
  return this.item + this.left.itemCheck() - this.right.itemCheck();
};
function bottomUpTree(item,depth){
  if(depth>0) return new TreeNode(bottomUpTree(2*item-1,depth-1),bottomUpTree(2*item,depth-1),item);
  return new TreeNode(null,null,item);
}
var ret=0;
for(var n=4;n<=6;n+=1){
  var minDepth=4, maxDepth=n, stretchDepth=maxDepth+1;
  var check=bottomUpTree(0,stretchDepth).itemCheck();
  var longLivedTree=bottomUpTree(0,maxDepth);
  for(var depth=minDepth;depth<=maxDepth;depth+=2){
    var iterations=1<<(maxDepth-depth+minDepth), c=0;
    for(var i=1;i<=iterations;i++){ c+=bottomUpTree(i,depth).itemCheck()+bottomUpTree(-i,depth).itemCheck(); }
  }
  ret += longLivedTree.itemCheck();
}
console.log("RESULT: "+ret);
