r = (1 + 0.001) ** (12 / 86400) - 1
debt = 1000
block_distance = 1000

print( debt * ((1 + r) ** (7200)))
