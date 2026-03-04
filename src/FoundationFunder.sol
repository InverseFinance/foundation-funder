// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title FoundationFunder
/// @notice A funding contract where a gov address streams quarterly token budgets
/// to a beneficiary, who can pull ERC20 tokens. Delegates can be authorized with sub-limits.
contract FoundationFunder {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant QUARTER_DURATION = 90 days;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroInterval();
    error TokenNotAllowed();
    error ExceedsAvailable(uint256 requested, uint256 available);

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event FundsPulled(address indexed caller, address indexed token, address indexed to, uint256 amount, string reason);
    event GovSet(address indexed oldGov, address indexed newGov);
    event BeneficiarySet(address indexed oldBeneficiary, address indexed newBeneficiary);
    event QuarterlyLimitSet(address indexed token, uint256 quarterlyLimit);
    event DelegateSet(
        address indexed delegate, address indexed token, uint256 limitAmount, uint256 interval
    );

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Unified rate-limited bucket used for both quarterly token limits and delegate configs
    struct Bucket {
        uint256 limit;
        uint256 interval;
        uint256 available;
        uint256 lastUpdated;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    address public gov;
    address public beneficiary;

    /// @dev token address => Bucket (quarterly streaming limit set by gov)
    mapping(address => Bucket) public tokenBuckets;

    /// @dev delegate address => token address => Bucket
    mapping(address => mapping(address => Bucket)) public delegateConfigs;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _gov, address _beneficiary) {
        if (_gov == address(0)) revert ZeroAddress();
        if (_beneficiary == address(0)) revert ZeroAddress();
        gov = _gov;
        beneficiary = _beneficiary;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets a new gov address
    /// @param _gov The new gov address
    function setGov(address _gov) external {
        if (msg.sender != gov) revert Unauthorized();
        if (_gov == address(0)) revert ZeroAddress();
        emit GovSet(gov, _gov);
        gov = _gov;
    }

    /// @notice Sets a new beneficiary address
    /// @param _beneficiary The new beneficiary address
    function setBeneficiary(address _beneficiary) external {
        if (msg.sender != gov && msg.sender != beneficiary) revert Unauthorized();
        if (_beneficiary == address(0)) revert ZeroAddress();
        emit BeneficiarySet(beneficiary, _beneficiary);
        beneficiary = _beneficiary;
    }

    /// @notice Sets the quarterly streaming limit for a token
    /// @param _token The ERC20 token address
    /// @param _quarterlyLimit The new quarterly limit (0 disables the token)
    function setQuarterlyLimit(address _token, uint256 _quarterlyLimit) external {
        if (msg.sender != gov) revert Unauthorized();

        Bucket storage bucket = tokenBuckets[_token];

        // Accrue with old params before updating
        if (bucket.limit > 0) {
            bucket.available = getTokenAvailable(_token);
        }

        bucket.limit = _quarterlyLimit;
        bucket.interval = QUARTER_DURATION;
        if (bucket.available > _quarterlyLimit) {
            bucket.available = _quarterlyLimit;
        }
        bucket.lastUpdated = block.timestamp;

        emit QuarterlyLimitSet(_token, _quarterlyLimit);
    }

    /// @notice Sets or updates a delegate's streaming config for a specific token
    /// @param _delegate The delegate address
    /// @param _token The ERC20 token address
    /// @param _limitAmount The delegate's max bucket capacity (0 disables)
    /// @param _interval The interval in seconds over which limitAmount fully accrues
    function setDelegate(
        address _delegate,
        address _token,
        uint256 _limitAmount,
        uint256 _interval
    ) external {
        if (msg.sender != beneficiary) revert Unauthorized();
        if (_delegate == address(0)) revert ZeroAddress();
        if (_limitAmount > 0 && _interval == 0) revert ZeroInterval();

        Bucket storage bucket = delegateConfigs[_delegate][_token];

        // Accrue with old params before updating
        if (bucket.limit > 0) {
            bucket.available = getDelegateAvailable(_delegate, _token);
        }

        bucket.limit = _limitAmount;
        bucket.interval = _interval;
        if (_limitAmount == 0) {
            bucket.available = 0;
        } else if (bucket.available > _limitAmount) {
            bucket.available = _limitAmount;
        }
        bucket.lastUpdated = block.timestamp;

        emit DelegateSet(_delegate, _token, _limitAmount, _interval);
    }

    /*//////////////////////////////////////////////////////////////
                          PULL FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Pulls ERC20 tokens from gov's balance
    /// @param _token The ERC20 token to pull
    /// @param _amount The amount to pull
    /// @param _to The recipient address
    /// @param _reason The reason for the pull (emitted in event)
    function pull(address _token, uint256 _amount, address _to, string calldata _reason)
        external
    {
        if (_amount == 0) revert ZeroAmount();
        if (_to == address(0)) revert ZeroAddress();

        bool isBeneficiary = msg.sender == beneficiary;
        bool isDelegate = delegateConfigs[msg.sender][_token].limit > 0;

        if (!isBeneficiary && !isDelegate) revert Unauthorized();

        // Update and check quarterly bucket (required for both beneficiary and delegate)
        if (tokenBuckets[_token].limit == 0) revert TokenNotAllowed();
        _updateAndConsume(tokenBuckets[_token], _amount);

        // If delegate, also check delegate bucket
        if (isDelegate) {
            _updateAndConsume(delegateConfigs[msg.sender][_token], _amount);
        }

        SafeTransferLib.safeTransferFrom(_token, gov, _to, _amount);

        emit FundsPulled(msg.sender, _token, _to, _amount, _reason);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current available amount for a token's quarterly bucket
    /// @param _token The token address
    /// @return The currently available amount
    function getTokenAvailable(address _token) public view returns (uint256) {
        return _getAvailable(tokenBuckets[_token]);
    }

    /// @notice Returns the current available amount for a delegate's token bucket
    /// @param _delegate The delegate address
    /// @param _token The token address
    /// @return The currently available amount
    function getDelegateAvailable(address _delegate, address _token)
        public
        view
        returns (uint256)
    {
        return _getAvailable(delegateConfigs[_delegate][_token]);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the current available amount for a bucket, including accrued amount
    function _getAvailable(Bucket storage bucket) internal view returns (uint256) {
        if (bucket.limit == 0) return 0;
        uint256 elapsed = block.timestamp - bucket.lastUpdated;
        uint256 accrued = bucket.limit * elapsed / bucket.interval;
        uint256 currentAvailable = bucket.available + accrued;
        if (currentAvailable > bucket.limit) currentAvailable = bucket.limit;
        return currentAvailable;
    }

    /// @dev Accrues a bucket and consumes the requested amount
    function _updateAndConsume(Bucket storage bucket, uint256 _amount) internal {
        uint256 currentAvailable = _getAvailable(bucket);
        if (_amount > currentAvailable) revert ExceedsAvailable(_amount, currentAvailable);
        bucket.available = currentAvailable - _amount;
        bucket.lastUpdated = block.timestamp;
    }
}
