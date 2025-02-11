// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console2 } from "forge-std/Test.sol";
import { ClaimsHatter } from "src/ClaimsHatter.sol";
import { IHats } from "hats-protocol/Interfaces/IHats.sol";
import { HatsErrors } from "hats-protocol/Interfaces/HatsErrors.sol";
import { ClaimsHatterFactoryTest } from "test/ClaimsHatterFactory.t.sol";
import { LibClone } from "solady/utils/LibClone.sol";

contract ClaimsHatterTest is ClaimsHatterFactoryTest {
  ClaimsHatter hatter;
  address public admin1;
  address public claimer1;
  address public eligibility;
  address public bot;

  uint256 public hatterHat1;
  uint256 public claimerHat1;

  error ClaimsHatter_NotClaimableFor();
  error ClaimsHatter_NotHatAdmin();
  error ClaimsHatter_NotExplicitlyEligible();

  event ClaimingForChanged(uint256 _hatId, bool _claimableFor);
  // ERC1155 Transfer event
  event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 amount);

  function setUp() public virtual override {
    super.setUp();
    // set up addresses
    admin1 = makeAddr("admin1");
    claimer1 = makeAddr("claimer1");
    eligibility = makeAddr("eligibility");
    bot = makeAddr("bot");

    vm.startPrank(admin1);
    // mint top hat to admin1
    topHat1 = hats.mintTopHat(admin1, "Top hat", "");
    // create hatterHat1
    hatterHat1 = hats.createHat(topHat1, "hatterHat1", 2, address(1), address(1), true, "");
    // derive id of claimHat1
    claimerHat1 = hats.buildHatId(hatterHat1, 1);
    // deploy an instance from the factory, for claimerHat1
    hatter = factory.createClaimsHatter(claimerHat1);
    vm.stopPrank();
  }

  /// @notice Mocks a call to the eligibility contract for `wearer` and `hat` that returns `eligible` and `standing`
  function mockEligibityCall(address wearer, uint256 hat, bool eligible, bool standing) public {
    bytes memory data = abi.encodeWithSignature("getWearerStatus(address,uint256)", wearer, hat);
    vm.mockCall(eligibility, data, abi.encode(eligible, standing));
  }
}

contract HatCreatedTest is ClaimsHatterTest {
  function setUp() public virtual override {
    super.setUp();
    // create claimerHat1 with good eligibility module
    vm.prank(admin1);
    claimerHat1 = hats.createHat(hatterHat1, "claimerHat1", 2, eligibility, address(1), true, "");
  }
}

contract ClaimsHatterHarness is ClaimsHatter {
  function mint(address _wearer) public {
    _mint(_wearer);
  }

  function isExplicitlyEligible(address _wearer) public view returns (bool) {
    return _isExplicitlyEligible(_wearer);
  }

  function checkOnlyAdminOrFactory() public view onlyAdminOrFactory returns (bool) {
    return true;
  }

  function checkOnlyAdmin() public view onlyAdmin returns (bool) {
    return true;
  }
}

contract InternalTest is HatCreatedTest {
  ClaimsHatterHarness harnessImplementation;
  ClaimsHatterHarness harness;

  function setUp() public virtual override {
    super.setUp();
    // deploy harness implementation
    harnessImplementation = new ClaimsHatterHarness();
    // deploy harness proxy
    harness = ClaimsHatterHarness(
      LibClone.cloneDeterministic(
        address(harnessImplementation), abi.encodePacked(address(this), hats, claimerHat1), bytes32("salt")
      )
    );
    // mint hatterHat1 to harness contract
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(harness));
  }
}

contract _isExplicitlyEligible is InternalTest {
  function test_eligibleWearer_isExplicitlyEligible() public {
    mockEligibityCall(claimer1, claimerHat1, true, true);
    assertTrue(harness.isExplicitlyEligible(claimer1));
  }

  function test_ineligibleWearer_isNotEligible() public {
    mockEligibityCall(claimer1, claimerHat1, false, true);
    assertFalse(harness.isExplicitlyEligible(claimer1));
  }

  function test_eligibleWearerInBadStanding_isNotEligible() public {
    mockEligibityCall(claimer1, claimerHat1, true, false);
    assertFalse(harness.isExplicitlyEligible(claimer1));
  }

  function test_humanisticEligibility_isNotExplicitlyEligible() public {
    assertFalse(harness.isExplicitlyEligible(claimer1));
  }
}

contract _Mint is InternalTest {
  function test_forEligible_mintSucceeds() public {
    mockEligibityCall(claimer1, claimerHat1, true, true);
    vm.prank(claimer1);
    harness.mint(claimer1);
    assertTrue(hats.isWearerOfHat(claimer1, claimerHat1));
  }

  function test_forIneligible_mintFails() public {
    mockEligibityCall(claimer1, claimerHat1, false, true);
    vm.prank(claimer1);
    vm.expectRevert(ClaimsHatter_NotExplicitlyEligible.selector);
    harness.mint(claimer1);
    assertFalse(hats.isWearerOfHat(claimer1, claimerHat1));
  }
}

contract _OnlyAdminOrFactory is InternalTest {
  function test_forAdmin_returnsTrue() public {
    vm.prank(admin1);
    assertTrue(harness.checkOnlyAdminOrFactory());
  }

  function test_forFactory_returnsTrue() public {
    vm.prank(address(this)); // this contract served as the factory for the harness
    assertTrue(harness.checkOnlyAdminOrFactory());
  }

  function test_forNonAdminOrFactory_reverts() public {
    vm.prank(claimer1); // claimer does not wear the admin hat (top hat)
    vm.expectRevert(ClaimsHatter_NotHatAdmin.selector);
    harness.checkOnlyAdminOrFactory();
  }
}

contract _onlyAdmin is InternalTest {
  function test_forAdmin_returnsTrue() public {
    vm.prank(admin1);
    assertTrue(harness.checkOnlyAdmin());
  }

  function test_forNonAdmin_reverts() public {
    vm.prank(claimer1); // claimer does not wear the admin hat (top hat)
    vm.expectRevert(ClaimsHatter_NotHatAdmin.selector);
    harness.checkOnlyAdmin();
  }
}

contract EnableClaimingFor is HatCreatedTest {
  function test_adminCall_succeeds() public {
    vm.expectEmit(true, true, true, true);
    emit ClaimingForChanged(claimerHat1, true);
    vm.prank(admin1);
    hatter.enableClaimingFor();
    // should be false since hatter does not yet wear hatterHat1
    assertFalse(hatter.claimableFor());
    // mint hatterHat1 to hatter
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(hatter));
    // now it should be true
    assertTrue(hatter.claimableFor());
  }

  function test_nonAdminCall_reverts() public {
    vm.expectRevert(ClaimsHatter_NotHatAdmin.selector);
    vm.prank(claimer1);
    hatter.enableClaimingFor();
  }
}

contract DisableClaimingFor is HatCreatedTest {
  function setUp() public override {
    super.setUp();
    // mint hatterHat1 to hatter
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(hatter));
    // enable claiming for
    vm.prank(admin1);
    hatter.enableClaimingFor();
  }

  function test_adminCall_succeeds() public {
    // claimableFor starts out as true
    assertTrue(hatter.claimableFor());
    // now we disable it
    vm.expectEmit(true, true, true, true);
    emit ClaimingForChanged(claimerHat1, false);
    vm.prank(admin1);
    hatter.disableClaimingFor();
    // now it should be false
    assertFalse(hatter.claimableFor());
  }

  function test_nonAdminCall_reverts() public {
    vm.expectRevert(ClaimsHatter_NotHatAdmin.selector);
    vm.prank(claimer1);
    hatter.disableClaimingFor();
  }
}

contract Claim is HatCreatedTest {
  function setUp() public override {
    super.setUp();
    // mint hatterHat1 to hatter
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(hatter));
  }

  function test_eligibleWearer_canClaim() public {
    // mock explicitly eligibility for claimer1
    mockEligibityCall(claimer1, claimerHat1, true, true);
    // attempt the claim, expecting a transfer event when minted
    vm.prank(claimer1);
    vm.expectEmit(true, true, true, true);
    emit TransferSingle(address(hatter), address(0), address(claimer1), claimerHat1, 1);
    hatter.claimHat();
    // claimer1 should now wear claimerHat1
    assertTrue(hats.isWearerOfHat(claimer1, claimerHat1));
  }

  function test_ineligibleWearer_cannotClaim() public {
    vm.prank(claimer1);
    vm.expectRevert(ClaimsHatter_NotExplicitlyEligible.selector);
    hatter.claimHat();
  }
}

contract ClaimFor is HatCreatedTest {
  function setUp() public override {
    super.setUp();
    // mint hatterHat1 to hatter
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(hatter));
    // enable claiming for
    vm.prank(admin1);
    hatter.enableClaimingFor();
  }

  function test_eligibleWearer_canBeClaimedFor() public {
    // mock explicitly eligibility for claimer1
    mockEligibityCall(claimer1, claimerHat1, true, true);
    // attempt the claim from another address, expecting a transfer event when minted
    vm.prank(bot);
    vm.expectEmit(true, true, true, true);
    emit TransferSingle(address(hatter), address(0), address(claimer1), claimerHat1, 1);
    hatter.claimHatFor(claimer1);
    // claimer1 should now wear claimerHat1
    assertTrue(hats.isWearerOfHat(claimer1, claimerHat1));
  }

  function test_ineligibleWearer_cannotBeClaimedFor() public {
    // attempt the claim from another address, expecting a revert
    vm.prank(bot);
    vm.expectRevert(ClaimsHatter_NotExplicitlyEligible.selector);
    hatter.claimHatFor(claimer1);

    // this should also happen if the wearer is explicitly ineligible
    // mock explicit ineligibility for claimer1
    mockEligibityCall(claimer1, claimerHat1, false, true);
    // attempt the claim from another address, expecting a revert
    vm.prank(bot);
    vm.expectRevert(ClaimsHatter_NotExplicitlyEligible.selector);
    hatter.claimHatFor(claimer1);
  }

  function test_eligibleWearer_notClaimableFor_cannotBeClaimedFor() public {
    // disable claiming for
    vm.prank(admin1);
    hatter.disableClaimingFor();
    // mock explicitly eligibility for claimer1
    mockEligibityCall(claimer1, claimerHat1, true, true);
    // attempt the claim from another address, expecting a revert
    vm.prank(bot);
    vm.expectRevert(ClaimsHatter_NotClaimableFor.selector);
    hatter.claimHatFor(claimer1);
  }
}

contract ViewFunctions is ClaimsHatterTest {
  function test_wearsAdmin() public {
    // claimable starts out as false since hatter does not yet wear hatterHat1
    assertFalse(hatter.wearsAdmin());
    // mint hatterHat1 to hatter
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(hatter));
    // now it should be true
    assertTrue(hatter.wearsAdmin());
    // now hatter gets rid of hatterHat1
    vm.prank(address(hatter));
    hats.renounceHat(hatterHat1);
    // now it should be false again
    assertFalse(hatter.wearsAdmin());
  }

  function test_claimable() public {
    // claimable starts out as false since hatter does not yet wear hatterHat1
    assertFalse(hatter.claimable());
    // mint hatterHat1 to hatter
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(hatter));
    // should still be false since claimerHat1 doesn't exist yet
    assertFalse(hatter.claimable());
    // create claimerHat1
    vm.prank(admin1);
    hats.createHat(hatterHat1, "claimerHat1", 2, eligibility, address(1), true, "");
    // now it should be true
    assertTrue(hatter.claimable());
    // now hatter gets rid of hatterHat1
    vm.prank(address(hatter));
    hats.renounceHat(hatterHat1);
    // now it should be false again
    assertFalse(hatter.claimable());
  }

  function test_claimableFor() public {
    // claimableFor starts out as false
    assertFalse(hatter.claimableFor());
    // now we enable it
    vm.prank(admin1);
    hatter.enableClaimingFor();
    // should still be false since claimerHat1 doesn't exist yet
    assertFalse(hatter.claimable());
    // create claimerHat1
    vm.prank(admin1);
    hats.createHat(hatterHat1, "claimerHat1", 2, eligibility, address(1), true, "");
    // should still be false since hatter does not yet wear hatterHat1
    assertFalse(hatter.claimableFor());
    // mint hatterHat1 to hatter
    vm.prank(admin1);
    hats.mintHat(hatterHat1, address(hatter));
    // now it should be true
    assertTrue(hatter.claimableFor());
    // now we disable it
    vm.prank(admin1);
    hatter.disableClaimingFor();
    // now it should be false again
    assertFalse(hatter.claimableFor());
  }
}
