// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract MembershipV1 is Initializable, AccessControlUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TORCH_RUNNER_ROLE = keccak256("TORCH_RUNNER_ROLE");

    address private constant ROOT_REFERRER_SENTINEL = address(1);

    struct Member {
        uint256 level;
        address referrer;
        address[] children;
    }

    mapping(address => Member) private _members;
    address public rootReferrer;

    event MemberJoined(uint256 level, address indexed member, address indexed referrer);
    event MemberAssigned(address indexed member, address indexed referrer, address indexed operator);
    event MemberReassigned(
        address indexed member,
        address indexed oldReferrer,
        address indexed newReferrer,
        uint256 newLevel,
        address operator
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address torchRunner_, address tokenAddress_) external initializer {
        __AccessControl_init();

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TORCH_RUNNER_ROLE, ADMIN_ROLE);

        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(TORCH_RUNNER_ROLE, _msgSender());
        _grantRole(TORCH_RUNNER_ROLE, torchRunner_);

        rootReferrer = tokenAddress_;
        _members[tokenAddress_].level = 1;
        _members[tokenAddress_].referrer = ROOT_REFERRER_SENTINEL;
        emit MemberJoined(1, tokenAddress_, ROOT_REFERRER_SENTINEL);
    }

    function members(address account) external view returns (uint256 level, address referrer) {
        Member storage m = _members[account];
        return (m.level, m.referrer);
    }

    function referrerOf(address account) external view returns (address) {
        return _members[account].referrer;
    }

    function childrenCountOf(address account) external view returns (uint256) {
        return _members[account].children.length;
    }

    function childrenOf(address account, uint256 offset, uint256 limit)
        external
        view
        returns (uint256 total, uint256 off, address[] memory page)
    {
        address[] storage list = _members[account].children;
        total = list.length;
        require(offset + limit <= total, "Exceeds length");
        page = new address[](limit);
        for (uint256 i = 0; i < limit; i++) {
            page[i] = list[offset + i];
        }
        off = offset;
    }

    function childrenRange(address account, uint256 from, uint256 to)
        external
        view
        returns (address[] memory page)
    {
        address[] storage list = _members[account].children;
        uint256 end = to > list.length ? list.length : to;
        if (from >= end) {
            return new address[](0);
        }
        page = new address[](end - from);
        for (uint256 i = 0; i < end - from; i++) {
            page[i] = list[from + i];
        }
    }

    function join(address referrer) external {
        _writeReferrer(referrer, _msgSender(), false);
    }

    function assignReferrer(address referrer, address member)
        external
        onlyRole(TORCH_RUNNER_ROLE)
    {
        _writeReferrer(referrer, member, true);
        emit MemberAssigned(member, _effectiveReferrer(referrer), _msgSender());
    }

    function assignReferrerBatch(address[] calldata referrers, address[] calldata members_)
        external
        onlyRole(TORCH_RUNNER_ROLE)
    {
        require(referrers.length == members_.length, "Length not match");
        for (uint256 i = 0; i < referrers.length; i++) {
            _writeReferrer(referrers[i], members_[i], true);
            emit MemberAssigned(members_[i], _effectiveReferrer(referrers[i]), _msgSender());
        }
    }

    function _writeReferrer(address referrer, address member, bool allowReassign) internal {
        address effectiveReferrer = _effectiveReferrer(referrer);

        // Allow pure EOAs and EIP-7702-delegated EOAs only. Plain smart
        // contracts (Gnosis Safe, 4337 wallets, anything else with arbitrary
        // bytecode) stay out so the referral tree keeps a 1:1 person↔account
        // shape and stays auditable. 7702-delegated EOAs are recognised by
        // their `0xef0100 || delegate` 23-byte designator (EIP-3541 reserves
        // the 0xef prefix so no real contract can collide).
        require(_isEoaOrEip7702(effectiveReferrer), "Forbidden contract");
        require(_isEoaOrEip7702(member), "Forbidden contract");
        require(effectiveReferrer != member, "Illegal relation");
        require(member != address(0) && member != ROOT_REFERRER_SENTINEL, "Illegal member");
        require(
            effectiveReferrer != address(0) && effectiveReferrer != ROOT_REFERRER_SENTINEL,
            "Illegal referrer"
        );
        require(_members[effectiveReferrer].referrer != address(0), "Referrer is not member");

        address oldReferrer = _members[member].referrer;
        if (oldReferrer == address(0)) {
            uint256 newLevel = _members[effectiveReferrer].level + 1;
            _members[member].referrer = effectiveReferrer;
            _members[member].level = newLevel;
            _members[effectiveReferrer].children.push(member);
            emit MemberJoined(newLevel, member, effectiveReferrer);
            return;
        }

        require(allowReassign, "Already joined");
        require(oldReferrer != effectiveReferrer, "Referrer unchanged");

        // Cycle prevention: new referrer must not be a descendant of `member`.
        // Walk the new referrer's ancestor chain — every chain terminates at
        // ROOT_REFERRER_SENTINEL because the root is the only member whose
        // referrer is the sentinel, and every other member's referrer is
        // itself a registered member.
        address cursor = effectiveReferrer;
        while (cursor != ROOT_REFERRER_SENTINEL) {
            require(cursor != member, "Creates cycle");
            cursor = _members[cursor].referrer;
        }

        _removeChild(oldReferrer, member);
        uint256 reassignedLevel = _members[effectiveReferrer].level + 1;
        _members[member].referrer = effectiveReferrer;
        _members[member].level = reassignedLevel;
        _members[effectiveReferrer].children.push(member);
        // Descendant levels are intentionally NOT cascaded — `level` is a
        // display field with no on-chain consumer, and a full subtree walk
        // would be unbounded. Off-chain indexers can recompute if needed.
        emit MemberReassigned(member, oldReferrer, effectiveReferrer, reassignedLevel, _msgSender());
    }

    function _removeChild(address parent, address child) internal {
        address[] storage list = _members[parent].children;
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == child) {
                uint256 last = len - 1;
                if (i != last) {
                    list[i] = list[last];
                }
                list.pop();
                return;
            }
        }
        revert("Child not found");
    }

    function _effectiveReferrer(address referrer) internal view returns (address) {
        return referrer == address(0) ? rootReferrer : referrer;
    }

    // True for a pure EOA (no code) or an EIP-7702-delegated EOA (exactly the
    // 23-byte `0xef0100 || delegate` designator). False for everything else,
    // i.e. ordinary smart contracts. EIP-3541 forbids real deployed contracts
    // from starting with `0xef`, so the prefix check cannot be spoofed.
    function _isEoaOrEip7702(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        if (size == 0) return true;
        if (size != 23) return false;
        bytes32 word;
        assembly {
            // Copy the 23-byte designator into scratch space (0x00..0x1f),
            // zero-padding the trailing 9 bytes, then load as a 32-byte word.
            extcodecopy(account, 0x00, 0, 32)
            word := mload(0x00)
        }
        // Top 3 bytes of `word` are the designator prefix: must be 0xef0100.
        return uint256(word) >> 232 == 0xef0100;
    }

    uint256[48] private __gap;
}
