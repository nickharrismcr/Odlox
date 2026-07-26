import time

class Tree:
    def __init__(self, item, depth):
        self.item = item
        if depth > 0:
            item2 = item + item
            depth -= 1
            self.left = Tree(item2 - 1, depth)
            self.right = Tree(item2, depth)
        else:
            self.left = None
            self.right = None

    def check(self):
        if self.left is None:
            return self.item
        return self.item + self.left.check() - self.right.check()

min_depth = 4
max_depth = 16
stretch_depth = max_depth + 1

start = time.perf_counter()

print("stretch tree of depth:")
print(stretch_depth)
print("check:")
print(Tree(0, stretch_depth).check())

long_lived_tree = Tree(0, max_depth)

iterations = 1 << max_depth

depth = min_depth
while depth < stretch_depth:
    check = 0
    i = 1
    while i <= iterations:
        check += Tree(i, depth).check() + Tree(-i, depth).check()
        i += 1
    print("num trees:"); print(iterations * 2)
    print("depth:"); print(depth)
    print("check:"); print(check)
    iterations //= 4
    depth += 2

print("long lived tree of depth:"); print(max_depth)
print("check:"); print(long_lived_tree.check())
print("elapsed:"); print(time.perf_counter() - start)
