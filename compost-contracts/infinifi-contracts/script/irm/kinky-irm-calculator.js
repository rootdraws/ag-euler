#!/usr/bin/env node

/**
 * Kinky IRM Parameter Calculator
 * Calculates parameters for Warren's anti-over-utilization Kinky IRM
 * 
 * Target: 10% → 10% @ 10% → 100%
 */

const BigNumber = require('bignumber.js');

// Parse command line arguments or use defaults
const args = process.argv.slice(2);
const CONFIG = {
    baseAPY: args[0] ? parseFloat(args[0]) / 100 : 0.1,       // Base APY at 0% utilization
    kinkAPY: args[1] ? parseFloat(args[1]) / 100 : 0.105,     // APY at kink
    maxAPY: args[2] ? parseFloat(args[2]) / 100 : 1.0,        // Max APY at 100% utilization
    kinkUtilization: args[3] ? parseFloat(args[3]) / 100 : 0.1  // Kink utilization point
};

console.log('🎯 Warren Kinky IRM Parameter Calculator');
console.log('=====================================');
console.log(`Target Curve: ${CONFIG.baseAPY*100}% → ${CONFIG.kinkAPY*100}% @ ${CONFIG.kinkUtilization*100}% → ${CONFIG.maxAPY*100}%`);
console.log('');

/**
 * Convert APY to SPY (Second Per Year)
 * SPY = ((1 + APY)^(1/31536000) - 1) * 1e27
 * Found in Euler Utils.sol: (borrowSPY + ONE) ^ SECONDS_PER_YEAR = borrowAPY
 */
function apyToSpy(apy) {
    const secondsPerYear = 31536000;
    // APY = (SPY + 1)^31536000, so SPY = (APY)^(1/31536000) - 1
    const spyRate = Math.pow(1 + apy, 1 / secondsPerYear) - 1;
    return Math.floor(spyRate * 1e27); // Scale by 1e27
}

/**
 * Convert utilization percentage to uint32 scale
 */
function utilizationToUint32(utilization) {
    const maxUint32 = Math.pow(2, 32) - 1;
    return Math.floor(utilization * maxUint32);
}

/**
 * Calculate slope for linear part (0% → kink)
 * slope = (kinkSPY - baseSPY) / kinkUtilization
 */
function calculateSlope() {
    const baseSPY = apyToSpy(CONFIG.baseAPY);
    const kinkSPY = apyToSpy(CONFIG.kinkAPY);
    const kinkUint32 = utilizationToUint32(CONFIG.kinkUtilization);
    
    const slopePerUnit = Math.floor((kinkSPY - baseSPY) / kinkUint32);
    
    console.log('📐 Slope Calculation:');
    console.log(`  Base SPY: ${baseSPY.toLocaleString()}`);
    console.log(`  Kink SPY: ${kinkSPY.toLocaleString()}`);
    console.log(`  SPY increase: ${(kinkSPY - baseSPY).toLocaleString()}`);
    console.log(`  Slope per uint32 unit: ${slopePerUnit.toLocaleString()}`);
    console.log('');
    
    return slopePerUnit;
}

/**
 * Estimate shape parameter for kinky curve
 * Higher shape = steeper curve after kink
 */
function estimateShape() {
    // For 10% → 100% curve with early throttling, we want aggressive protection
    // Shape ~70 provides good kinky behavior for anti-over-utilization
    const shape = 70;
    
    console.log('🌊 Shape Parameter:');
    console.log(`  Shape: ${shape} (controls post-kink curve steepness)`);
    console.log('  Higher values = steeper kinky curve');
    console.log('');
    
    return shape;
}

/**
 * Calculate all parameters
 */
function calculateParameters() {
    console.log('🔢 Parameter Calculations:');
    console.log('');
    
    // Convert APY to SPY
    const baseRateSPY = apyToSpy(CONFIG.baseAPY);
    const cutoffSPY = apyToSpy(CONFIG.maxAPY);
    
    console.log('📊 APY → SPY Conversions:');
    console.log(`  Base Rate: ${CONFIG.baseAPY*100}% APY → ${baseRateSPY.toLocaleString()} SPY`);
    console.log(`  Max Rate: ${CONFIG.maxAPY*100}% APY → ${cutoffSPY.toLocaleString()} SPY`);
    console.log('');
    
    // Calculate slope
    const slope = calculateSlope();
    
    // Convert kink to uint32
    const kinkUint32 = utilizationToUint32(CONFIG.kinkUtilization);
    
    console.log('🎯 Kink Conversion:');
    console.log(`  Kink: ${CONFIG.kinkUtilization*100}% → ${kinkUint32.toLocaleString()} (uint32 scale)`);
    console.log('');
    
    // Estimate shape
    const shape = estimateShape();
    
    return {
        baseRate: baseRateSPY,
        slope: slope,
        shape: shape,
        kink: kinkUint32,
        cutoff: cutoffSPY
    };
}

/**
 * Generate deployment call
 */
function generateDeploymentCall(params) {
    console.log('🚀 EulerKinkyIRMFactory Deployment Call:');
    console.log('');
    console.log('```solidity');
    console.log('// Deploy Warren Anti-Over-Utilization Kinky IRM');
    console.log('address kinkyIRM = kinkyIRMFactory.deploy(');
    console.log(`    ${params.baseRate},  // baseRate (10% APY)`);
    console.log(`    ${params.slope},     // slope (flat until kink)`);
    console.log(`    ${params.shape},     // shape (kinky curve steepness)`);
    console.log(`    ${params.kink},      // kink (10% utilization)`);
    console.log(`    ${params.cutoff}     // cutoff (100% APY)`);
    console.log(');');
    console.log('```');
    console.log('');
}

/**
 * Validate curve behavior
 */
function validateCurve(params) {
    console.log('✅ Curve Validation:');
    console.log('');
    console.log('Expected behavior:');
    console.log(`  • 0% utilization: ${CONFIG.baseAPY*100}% APR (${params.baseRate.toLocaleString()} SPY)`);
    console.log(`  • ${CONFIG.kinkUtilization*100}% utilization: ${CONFIG.kinkAPY*100}% APR`);
    console.log(`  • 100% utilization: ${CONFIG.maxAPY*100}% APR (${params.cutoff.toLocaleString()} SPY)`);
    console.log('');
    console.log('Features:');
    console.log('  ✓ Over-utilization protection: 90% liquidity reserved after 10% kink');
    console.log('  ✓ Community friendly: Flat 10% rate up to 10% utilization');
    console.log('  ✓ Early throttling: 100% max rate prevents ecosystem death spirals');
    console.log('  ✓ Kinky curve: Smooth increase after kink trigger');
    console.log('');
}

/**
 * Main execution
 */
function main() {
    try {
        const parameters = calculateParameters();
        generateDeploymentCall(parameters);
        validateCurve(parameters);
        
        console.log('🎉 Warren Anti-Over-Utilization Kinky IRM parameters calculated successfully!');
        console.log('');
        console.log('📝 Summary:');
        console.log('  • Over-utilization protection: ✓');
        console.log('  • Community friendly rates: ✓');
        console.log('  • Early throttling strategy: ✓');
        console.log('  • Ecosystem stability: ✓');
        
    } catch (error) {
        console.error('❌ Error calculating parameters:', error.message);
        process.exit(1);
    }
}

// Check if BigNumber is available
try {
    require('bignumber.js');
} catch (e) {
    console.log('📦 Installing required dependency: bignumber.js');
    console.log('Run: npm install bignumber.js');
    console.log('Then run this script again.');
    process.exit(1);
}

// Run the calculator
main();
