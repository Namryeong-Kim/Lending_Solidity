r = (1 + 0.001) ** (12 / 86400) - 1
debt = 1000
block_distance = 1000

for i in range(10):
    debt = debt * ((1 + r) ** (block_distance))
    block_distance += 10000
    print(debt)