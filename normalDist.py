import numpy as np
from scipy.stats import norm
import json

def generate_liquidity_distribution(L, mean, std_dev, tick_spacing):
    # Generate tick values, ensuring they're divisible by tick_spacing
    max_tick = int(4 * std_dev)
    max_tick = max_tick - (max_tick % tick_spacing)  # Ensure max_tick is divisible by tick_spacing
    ticks = np.arange(-max_tick, max_tick + tick_spacing, tick_spacing)
    
    # Calculate probabilities for each tick range
    probabilities = np.diff(norm.cdf(ticks, loc=mean, scale=std_dev))
    probabilities /= probabilities.sum()
    
    # Calculate liquidity for each tick range
    liquidity = L * probabilities
    
    # Create list of [tickFrom, tickTo, liquidityWithinTheTick]
    tick_ranges = [
        [int(from_tick), int(to_tick), int(liq)]
        for from_tick, to_tick, liq in zip(ticks[:-1], ticks[1:], liquidity)
    ]
    
    return tick_ranges

# Parameters
L = 1e8 * 1e18 # 100M tokens
mean = 0
std_dev = 1000 # +- 4000 ticks
tick_spacing = 60

# Generate distribution
tick_ranges = generate_liquidity_distribution(L, mean, std_dev, tick_spacing)

# Convert to JSON and print to stdout
# json_output = json.dumps(tick_ranges, indent=2)
for range in tick_ranges:
    print(f"IPoolManager.ModifyLiquidityParams({{tickLower: {range[0]},tickUpper: {range[1]},liquidityDelta: {int(range[2])},salt: 0}}),")

# Optionally, verify total liquidity
total_liquidity = sum(range[2] for range in tick_ranges)
print(f"\nTotal liquidity: {int(total_liquidity)}")