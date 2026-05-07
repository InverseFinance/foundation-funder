// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FoundationFunder} from "../src/FoundationFunder.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FoundationFunderTest is Test {
    FoundationFunder public funder;
    MockERC20 public token;
    MockERC20 public token2;

    address public govAddr;
    address public beneficiaryAddr;
    address public delegate1;
    address public delegate2;
    address public recipient;
    address public random;

    uint256 constant QUARTER = 90 days;

    function setUp() public {
        govAddr = makeAddr("gov");
        beneficiaryAddr = makeAddr("beneficiary");
        delegate1 = makeAddr("delegate1");
        delegate2 = makeAddr("delegate2");
        recipient = makeAddr("recipient");
        random = makeAddr("random");

        token = new MockERC20("Test Token", "TT", 18);
        token2 = new MockERC20("Test Token 2", "TT2", 18);

        funder = new FoundationFunder(govAddr, beneficiaryAddr);

        token.mint(govAddr, 1_000_000e18);
        token2.mint(govAddr, 1_000_000e18);

        vm.startPrank(govAddr);
        token.approve(address(funder), type(uint256).max);
        token2.approve(address(funder), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsGovAndBeneficiary() public view {
        assertEq(funder.gov(), govAddr);
        assertEq(funder.beneficiary(), beneficiaryAddr);
    }

    function test_constructor_revertsOnZeroGov() public {
        vm.expectRevert(FoundationFunder.ZeroAddress.selector);
        new FoundationFunder(address(0), beneficiaryAddr);
    }

    function test_constructor_revertsOnZeroBeneficiary() public {
        vm.expectRevert(FoundationFunder.ZeroAddress.selector);
        new FoundationFunder(govAddr, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          SET GOV TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setGov_success() public {
        address newGov = makeAddr("newGov");
        vm.prank(govAddr);
        funder.setGov(newGov);
        assertEq(funder.gov(), newGov);
    }

    function test_setGov_emitsEvent() public {
        address newGov = makeAddr("newGov");
        vm.expectEmit(true, true, false, false);
        emit FoundationFunder.GovSet(govAddr, newGov);
        vm.prank(govAddr);
        funder.setGov(newGov);
    }

    function test_setGov_revertsIfNotGov() public {
        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.setGov(makeAddr("newGov"));
    }

    function test_setGov_revertsOnZeroAddress() public {
        vm.prank(govAddr);
        vm.expectRevert(FoundationFunder.ZeroAddress.selector);
        funder.setGov(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      SET BENEFICIARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setBeneficiary_byGov() public {
        address newBen = makeAddr("newBen");
        vm.prank(govAddr);
        funder.setBeneficiary(newBen);
        assertEq(funder.beneficiary(), newBen);
    }

    function test_setBeneficiary_byBeneficiary() public {
        address newBen = makeAddr("newBen");
        vm.prank(beneficiaryAddr);
        funder.setBeneficiary(newBen);
        assertEq(funder.beneficiary(), newBen);
    }

    function test_setBeneficiary_emitsEvent() public {
        address newBen = makeAddr("newBen");
        vm.expectEmit(true, true, false, false);
        emit FoundationFunder.BeneficiarySet(beneficiaryAddr, newBen);
        vm.prank(govAddr);
        funder.setBeneficiary(newBen);
    }

    function test_setBeneficiary_revertsIfUnauthorized() public {
        vm.prank(random);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.setBeneficiary(makeAddr("newBen"));
    }

    function test_setBeneficiary_revertsOnZeroAddress() public {
        vm.prank(govAddr);
        vm.expectRevert(FoundationFunder.ZeroAddress.selector);
        funder.setBeneficiary(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    SET QUARTERLY LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setQuarterlyLimit_success() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        (uint256 limit, uint256 interval, uint256 available, uint256 lastUpdated) =
            funder.tokenBuckets(address(token));
        assertEq(limit, 1000e18);
        assertEq(interval, 90 days);
        assertEq(available, 0);
        assertEq(lastUpdated, block.timestamp);
    }

    function test_setQuarterlyLimit_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit FoundationFunder.QuarterlyLimitSet(address(token), 1000e18);
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
    }

    function test_setQuarterlyLimit_revertsIfNotGov() public {
        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.setQuarterlyLimit(address(token), 1000e18);
    }

    function test_setQuarterlyLimit_midStreamIncrease() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        // Wait half a quarter
        vm.warp(block.timestamp + QUARTER / 2);

        // Increase limit
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 2000e18);

        (uint256 limit,, uint256 available,) = funder.tokenBuckets(address(token));
        assertEq(limit, 2000e18);
        // Should have accrued ~500e18 with old limit (1000 * 0.5)
        assertEq(available, 500e18);
    }

    function test_setQuarterlyLimit_midStreamDecrease() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        // Wait full quarter so available = 1000e18
        vm.warp(block.timestamp + QUARTER);

        // Decrease limit to 500e18
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 500e18);

        (uint256 limit,, uint256 available,) = funder.tokenBuckets(address(token));
        assertEq(limit, 500e18);
        // Available should be capped at new limit
        assertEq(available, 500e18);
    }

    function test_setQuarterlyLimit_setToZero() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        vm.warp(block.timestamp + QUARTER / 2);

        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 0);

        (uint256 limit,, uint256 available,) = funder.tokenBuckets(address(token));
        assertEq(limit, 0);
        assertEq(available, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       SET DELEGATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setDelegate_success() public {
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        (uint256 limit, uint256 interval, uint256 available, uint256 lastUpdated) =
            funder.delegateConfigs(delegate1, address(token));
        assertEq(limit, 100e18);
        assertEq(interval, 1 days);
        assertEq(available, 0);
        assertEq(lastUpdated, block.timestamp);
    }

    function test_setDelegate_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit FoundationFunder.DelegateSet(delegate1, address(token), 100e18, 1 days);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);
    }

    function test_setDelegate_revertsIfNotBeneficiary() public {
        vm.prank(govAddr);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);
    }

    function test_setDelegate_revertsOnZeroAddress() public {
        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.ZeroAddress.selector);
        funder.setDelegate(address(0), address(token), 100e18, 1 days);
    }

    function test_setDelegate_revertsOnZeroInterval() public {
        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.ZeroInterval.selector);
        funder.setDelegate(delegate1, address(token), 100e18, 0);
    }

    function test_setDelegate_allowsZeroLimitWithZeroInterval() public {
        // Disabling a delegate: limitAmount=0, interval=0 should work
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 0, 0);

        (uint256 limit,,,) = funder.delegateConfigs(delegate1, address(token));
        assertEq(limit, 0);
    }

    function test_setDelegate_updateConfig() public {
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        // Wait half the interval
        vm.warp(block.timestamp + 12 hours);

        // Update to larger limit
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 200e18, 2 days);

        (uint256 limit, uint256 interval, uint256 available,) =
            funder.delegateConfigs(delegate1, address(token));
        assertEq(limit, 200e18);
        assertEq(interval, 2 days);
        // Accrued ~50e18 with old config (100e18 * 0.5)
        assertEq(available, 50e18);
    }

    function test_setDelegate_disableThenReenable() public {
        vm.startPrank(beneficiaryAddr);

        funder.setDelegate(delegate1, address(token), 100e18, 1 days);
        vm.warp(block.timestamp + 1 days);

        // Disable
        funder.setDelegate(delegate1, address(token), 0, 0);
        (uint256 limit,, uint256 available,) =
            funder.delegateConfigs(delegate1, address(token));
        assertEq(limit, 0);
        assertEq(available, 0);

        // Re-enable
        funder.setDelegate(delegate1, address(token), 50e18, 12 hours);
        (limit,, available,) = funder.delegateConfigs(delegate1, address(token));
        assertEq(limit, 50e18);
        assertEq(available, 0);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    BENEFICIARY PULL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_pull_beneficiary_success() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        // Wait full quarter
        vm.warp(block.timestamp + QUARTER);

        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 500e18, recipient, "Grant for Q1");

        assertEq(token.balanceOf(recipient), 500e18);
    }

    function test_pull_beneficiary_emitsEvent() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        vm.warp(block.timestamp + QUARTER);

        vm.expectEmit(true, true, true, true);
        emit FoundationFunder.FundsPulled(beneficiaryAddr, address(token), recipient, 500e18, "Test reason");

        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 500e18, recipient, "Test reason");
    }

    function test_pull_beneficiary_revertsIfUnauthorized() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.warp(block.timestamp + QUARTER);

        vm.prank(random);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.pull(address(token), 100e18, recipient, "reason");
    }

    function test_pull_beneficiary_revertsIfTokenNotAllowed() public {
        // Token has no limit set (default 0)
        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.TokenNotAllowed.selector);
        funder.pull(address(token), 100e18, recipient, "reason");
    }

    function test_pull_beneficiary_revertsIfExceedsAvailable() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        // Wait only 10% of the quarter
        vm.warp(block.timestamp + QUARTER / 10);

        // Try to pull more than accrued (~100e18)
        vm.prank(beneficiaryAddr);
        vm.expectRevert(
            abi.encodeWithSelector(FoundationFunder.ExceedsAvailable.selector, 200e18, 100e18)
        );
        funder.pull(address(token), 200e18, recipient, "reason");
    }

    function test_pull_beneficiary_revertsOnZeroAmount() public {
        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.ZeroAmount.selector);
        funder.pull(address(token), 0, recipient, "reason");
    }

    function test_pull_beneficiary_revertsOnZeroToAddress() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.warp(block.timestamp + QUARTER);

        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.ZeroAddress.selector);
        funder.pull(address(token), 100e18, address(0), "reason");
    }

    function test_pull_beneficiary_streamingAccrual() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        // Wait 25% of a quarter
        vm.warp(block.timestamp + QUARTER / 4);

        // Should have ~250e18 available
        uint256 available = funder.getTokenAvailable(address(token));
        assertEq(available, 250e18);

        // Pull exactly that amount
        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 250e18, recipient, "25% pull");

        assertEq(token.balanceOf(recipient), 250e18);
    }

    function test_pull_beneficiary_cappedAtQuarterlyLimit() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        // Wait 2 full quarters
        vm.warp(block.timestamp + QUARTER * 2);

        // Available should be capped at 1000e18
        uint256 available = funder.getTokenAvailable(address(token));
        assertEq(available, 1000e18);
    }

    function test_pull_beneficiary_multiplePulls() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        // Wait half quarter, pull 200
        vm.warp(block.timestamp + QUARTER / 2);
        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 200e18, recipient, "first pull");

        // Available should be 300e18 (500 - 200)
        (,,uint256 available,) = funder.tokenBuckets(address(token));
        assertEq(available, 300e18);

        // Wait another quarter, should accrue back to 1000e18 cap
        vm.warp(block.timestamp + QUARTER);
        uint256 currentAvailable = funder.getTokenAvailable(address(token));
        assertEq(currentAvailable, 1000e18);

        // Pull all 1000
        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 1000e18, recipient, "second pull");

        assertEq(token.balanceOf(recipient), 1200e18);
    }

    function test_pull_beneficiary_multipleTokens() public {
        vm.startPrank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        funder.setQuarterlyLimit(address(token2), 500e18);
        vm.stopPrank();

        vm.warp(block.timestamp + QUARTER);

        vm.startPrank(beneficiaryAddr);
        funder.pull(address(token), 800e18, recipient, "token1 pull");
        funder.pull(address(token2), 300e18, recipient, "token2 pull");
        vm.stopPrank();

        assertEq(token.balanceOf(recipient), 800e18);
        assertEq(token2.balanceOf(recipient), 300e18);
    }

    /*//////////////////////////////////////////////////////////////
                      DELEGATE PULL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_pull_delegate_success() public {
        // Set quarterly limit (high enough so daily accrual >= delegate limit)
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 9000e18);

        // Set delegate
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        // Wait for both to accrue
        vm.warp(block.timestamp + 1 days);

        vm.prank(delegate1);
        funder.pull(address(token), 50e18, recipient, "delegate pull");

        assertEq(token.balanceOf(recipient), 50e18);
    }

    function test_pull_delegate_emitsEvent() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 9000e18);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, true, true, true);
        emit FoundationFunder.FundsPulled(delegate1, address(token), recipient, 50e18, "delegate reason");

        vm.prank(delegate1);
        funder.pull(address(token), 50e18, recipient, "delegate reason");
    }

    function test_pull_delegate_revertsIfNotDelegate() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.warp(block.timestamp + QUARTER);

        // random has no delegate config
        vm.prank(random);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.pull(address(token), 100e18, recipient, "reason");
    }

    function test_pull_delegate_revertsIfExceedsDelegateBucket() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 100_000e18);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        // Wait half day: delegate has ~50e18
        vm.warp(block.timestamp + 12 hours);

        vm.prank(delegate1);
        vm.expectRevert(
            abi.encodeWithSelector(FoundationFunder.ExceedsAvailable.selector, 80e18, 50e18)
        );
        funder.pull(address(token), 80e18, recipient, "reason");
    }

    function test_pull_delegate_revertsIfExceedsQuarterlyBucket() public {
        // Small quarterly limit, large delegate limit
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 10e18);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 1000e18, 1 days);

        vm.warp(block.timestamp + 1 days);

        // Delegate has 1000e18 available but quarterly only has 10e18
        // The quarterly bucket check happens first
        uint256 quarterlyAvailable = funder.getTokenAvailable(address(token));

        vm.prank(delegate1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FoundationFunder.ExceedsAvailable.selector, 50e18, quarterlyAvailable
            )
        );
        funder.pull(address(token), 50e18, recipient, "reason");
    }

    function test_pull_delegate_doubleGated() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 9000e18);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        vm.warp(block.timestamp + 1 days);

        vm.prank(delegate1);
        funder.pull(address(token), 80e18, recipient, "double gated");

        // Check both buckets were decremented
        (,,uint256 tokenAvailable,) = funder.tokenBuckets(address(token));
        (,,uint256 delegateAvailable,) = funder.delegateConfigs(delegate1, address(token));

        // Quarterly: accrued 9000/90 = 100e18 in 1 day, minus 80
        uint256 expectedQuarterly = 9000e18 * 1 days / QUARTER - 80e18;
        assertEq(tokenAvailable, expectedQuarterly);

        // Delegate: accrued 100e18 in 1 day, minus 80
        assertEq(delegateAvailable, 20e18);
    }

    function test_pull_delegate_streamingAccrual() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        // Wait half the interval
        vm.warp(block.timestamp + 12 hours);

        uint256 available = funder.getDelegateAvailable(delegate1, address(token));
        assertEq(available, 50e18);
    }

    function test_pull_delegate_cappedAtLimitAmount() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        // Wait 5 days — should cap at 100e18
        vm.warp(block.timestamp + 5 days);

        uint256 available = funder.getDelegateAvailable(delegate1, address(token));
        assertEq(available, 100e18);
    }

    function test_pull_delegate_multipleDelegatesSharedQuarterly() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 100_000e18);

        vm.startPrank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);
        funder.setDelegate(delegate2, address(token), 200e18, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        // Both delegates pull, consuming from shared quarterly bucket
        vm.prank(delegate1);
        funder.pull(address(token), 50e18, recipient, "delegate1 pull");

        vm.prank(delegate2);
        funder.pull(address(token), 100e18, recipient, "delegate2 pull");

        assertEq(token.balanceOf(recipient), 150e18);

        // Quarterly bucket should have accrued ~1111e18 in 1 day - 150 consumed
        // Check it's less than the daily accrual (proves both pulls consumed from it)
        uint256 tokenAvailable = funder.getTokenAvailable(address(token));
        uint256 dailyAccrual = 100_000e18 * 1 days / QUARTER;
        assertTrue(tokenAvailable < dailyAccrual);
    }

    function test_pull_delegate_wrongToken() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token2), 1000e18);
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        vm.warp(block.timestamp + 1 days);

        // Delegate is set for token, not token2 — should revert as unauthorized
        vm.prank(delegate1);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.pull(address(token2), 50e18, recipient, "wrong token");
    }

    /*//////////////////////////////////////////////////////////////
                      VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getTokenAvailable_noLimitSet() public view {
        assertEq(funder.getTokenAvailable(address(token)), 0);
    }

    function test_getTokenAvailable_afterAccrual() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        vm.warp(block.timestamp + QUARTER / 4);
        assertEq(funder.getTokenAvailable(address(token)), 250e18);
    }

    function test_getTokenAvailable_cappedAtLimit() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        vm.warp(block.timestamp + QUARTER * 3);
        assertEq(funder.getTokenAvailable(address(token)), 1000e18);
    }

    function test_getDelegateAvailable_noConfigSet() public view {
        assertEq(funder.getDelegateAvailable(delegate1, address(token)), 0);
    }

    function test_getDelegateAvailable_afterAccrual() public {
        vm.prank(beneficiaryAddr);
        funder.setDelegate(delegate1, address(token), 100e18, 1 days);

        vm.warp(block.timestamp + 6 hours);
        assertEq(funder.getDelegateAvailable(delegate1, address(token)), 25e18);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_pull_afterGovChange() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.warp(block.timestamp + QUARTER);

        // Change gov
        address newGov = makeAddr("newGov");
        vm.prank(govAddr);
        funder.setGov(newGov);

        // Mint and approve for new gov
        token.mint(newGov, 1_000_000e18);
        vm.prank(newGov);
        token.approve(address(funder), type(uint256).max);

        // Pull should now transfer from new gov
        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 500e18, recipient, "from new gov");

        assertEq(token.balanceOf(recipient), 500e18);
    }

    function test_pull_afterBeneficiaryChange() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.warp(block.timestamp + QUARTER);

        // Change beneficiary
        address newBen = makeAddr("newBen");
        vm.prank(beneficiaryAddr);
        funder.setBeneficiary(newBen);

        // Old beneficiary cannot pull
        vm.prank(beneficiaryAddr);
        vm.expectRevert(FoundationFunder.Unauthorized.selector);
        funder.pull(address(token), 100e18, recipient, "old ben");

        // New beneficiary can pull
        vm.prank(newBen);
        funder.pull(address(token), 100e18, recipient, "new ben");

        assertEq(token.balanceOf(recipient), 100e18);
    }

    function test_pull_exactlyAvailable() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);

        vm.warp(block.timestamp + QUARTER);

        // Pull exactly 1000e18
        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 1000e18, recipient, "exact pull");

        assertEq(token.balanceOf(recipient), 1000e18);
        assertEq(funder.getTokenAvailable(address(token)), 0);
    }

    function test_pull_beneficiarySendsToSelf() public {
        vm.prank(govAddr);
        funder.setQuarterlyLimit(address(token), 1000e18);
        vm.warp(block.timestamp + QUARTER);

        vm.prank(beneficiaryAddr);
        funder.pull(address(token), 100e18, beneficiaryAddr, "to self");

        assertEq(token.balanceOf(beneficiaryAddr), 100e18);
    }
}
