import time

i = 0
loop_start = time.perf_counter()

while i < 50000000:
    i += 1
    1; 1; 1; 2; 1; None; 1; "str"; 1; True
    None; None; None; 1; None; "str"; None; True
    True; True; True; 1; True; False; True; "str"; True; None
    "str"; "str"; "str"; "stru"; "str"; 1; "str"; None; "str"; True

loop_time = time.perf_counter() - loop_start

i = 0
start = time.perf_counter()
while i < 50000000:
    i += 1
    1 == 1; 1 == 2; 1 == None; 1 == "str"; 1 == True
    None == None; None == 1; None == "str"; None == True
    True == True; True == 1; True == False; True == "str"; True == None
    "str" == "str"; "str" == "stru"; "str" == 1; "str" == None; "str" == True

elapsed = time.perf_counter() - start
print("loop"); print(loop_time)
print("elapsed"); print(elapsed)
print("equals"); print(elapsed - loop_time)
