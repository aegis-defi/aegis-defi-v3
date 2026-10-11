// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Read-only views needed for downline traversal.
interface IMembershipView {
    function members(address account) external view returns (uint256 level, address referrer);
    function childrenCountOf(address account) external view returns (uint256);
    function childrenRange(address account, uint256 from, uint256 to) external view returns (address[] memory);
    function rootReferrer() external view returns (address);
}

/// @notice Read-only ILO position view.
interface IILOView {
    function getUserPosition(address user) external view returns (
        uint256 contributed,
        uint256 gathMinted,
        uint256 nftCount,
        address referrer
    );
}

/// @title AdminAggregatorV1
/// @notice Off-chain helper aggregator for the Aegis Admin console.
///
///         The console needs to walk the membership downline of an address
///         and sum each descendant's ILO contribution. Doing that from a
///         JS client costs N+M RPC roundtrips (N = membership graph reads,
///         M = ILO position reads), which trips public-RPC rate limits on
///         large teams. This contract collapses the entire walk into a
///         single eth_call: the RPC node executes the BFS in EVM memory
///         and returns the totals in one response.
///
///         All functions are pure read paths (`view`) so this contract
///         needs no upgrade story — if the BFS strategy ever changes,
///         deploy a V2 alongside and switch the client. There is no
///         storage, no privileged functions, no external state. Both the
///         membership and ILO addresses are immutable to make that
///         contract-level read-only-ness obvious from the bytecode.
contract AdminAggregatorV1 {
    IMembershipView public immutable membership;
    IILOView public immutable ilo;

    constructor(address membership_, address ilo_) {
        require(membership_ != address(0) && ilo_ != address(0), "zero address");
        membership = IMembershipView(membership_);
        ilo = IILOView(ilo_);
    }

    struct TeamTotals {
        uint256 contributed;   // sum of usdcContributed across descendants
        uint256 gathMinted;    // sum of gathMinted across descendants
        uint256 nftCount;      // sum of NFTs minted across descendants
        uint256 members;       // count of descendants (root excluded)
        uint256 visited;       // total nodes touched, including root
        bool truncated;        // true if maxNodes capped the walk early
    }

    struct Position {
        uint256 contributed;
        uint256 gathMinted;
        uint256 nftCount;
        address referrer;
    }

    /// @notice BFS the subtree rooted at `root`, summing each descendant's
    ///         ILO position. The root itself is not counted — "team" here
    ///         means "downline".
    /// @param root The wallet whose downline to summarise.
    /// @param maxNodes Hard cap on nodes visited. Pass 0 for "no cap" (will
    ///         use type(uint256).max which in practice runs until the RPC
    ///         node hits its view-call gas limit). Recommended: 10_000.
    function getTeamSummary(address root, uint256 maxNodes) external view returns (TeamTotals memory totals) {
        if (root == address(0)) return totals;
        uint256 cap = maxNodes == 0 ? type(uint256).max : maxNodes;

        // BFS with a fixed-size queue. Memory allocation: ~32 bytes per slot
        // so 10_000 nodes = 320KB — fine for view calls. We allocate `cap+1`
        // so a `truncated` flag can fire on the first overflow attempt.
        uint256 alloc = cap == type(uint256).max ? 65_536 : (cap + 1);
        address[] memory queue = new address[](alloc);
        queue[0] = root;
        uint256 head = 0;
        uint256 tail = 1;
        bool isRoot = true;

        while (head < tail) {
            address current = queue[head++];

            if (!isRoot) {
                (uint256 c, uint256 g, uint256 n, ) = ilo.getUserPosition(current);
                totals.contributed += c;
                totals.gathMinted += g;
                totals.nftCount += n;
                unchecked { totals.members += 1; }
            }
            isRoot = false;

            uint256 cnt = membership.childrenCountOf(current);
            if (cnt == 0) continue;
            address[] memory kids = membership.childrenRange(current, 0, cnt);
            for (uint256 i = 0; i < kids.length; i++) {
                if (tail >= alloc || tail - 1 >= cap) {
                    // -1 because tail counts the root itself; descendants
                    // visited so far = tail-1. Once that reaches `cap` we
                    // stop accepting new nodes into the frontier.
                    totals.truncated = true;
                    break;
                }
                queue[tail++] = kids[i];
            }
            if (totals.truncated) break;
        }
        totals.visited = tail;
    }

    /// @notice Like getTeamSummary, but also returns the flat list of
    ///         descendants so the caller can drill into individual rows.
    ///         Costs more memory than getTeamSummary because the array is
    ///         materialised in calldata.
    function getTeamSummaryAndDownline(address root, uint256 maxNodes) external view returns (
        TeamTotals memory totals,
        address[] memory descendants
    ) {
        if (root == address(0)) {
            return (totals, new address[](0));
        }
        uint256 cap = maxNodes == 0 ? type(uint256).max : maxNodes;
        uint256 alloc = cap == type(uint256).max ? 65_536 : (cap + 1);

        address[] memory queue = new address[](alloc);
        queue[0] = root;
        uint256 head = 0;
        uint256 tail = 1;
        bool isRoot = true;

        while (head < tail) {
            address current = queue[head++];

            if (!isRoot) {
                (uint256 c, uint256 g, uint256 n, ) = ilo.getUserPosition(current);
                totals.contributed += c;
                totals.gathMinted += g;
                totals.nftCount += n;
                unchecked { totals.members += 1; }
            }
            isRoot = false;

            uint256 cnt = membership.childrenCountOf(current);
            if (cnt == 0) continue;
            address[] memory kids = membership.childrenRange(current, 0, cnt);
            for (uint256 i = 0; i < kids.length; i++) {
                if (tail >= alloc || tail - 1 >= cap) {
                    totals.truncated = true;
                    break;
                }
                queue[tail++] = kids[i];
            }
            if (totals.truncated) break;
        }
        totals.visited = tail;

        // Drop queue[0] (the root) and copy the rest into a right-sized array.
        uint256 outLen = tail - 1;
        descendants = new address[](outLen);
        for (uint256 i = 0; i < outLen; i++) {
            descendants[i] = queue[i + 1];
        }
    }

    /// @notice Batch ILO positions for a list of addresses. Useful when the
    ///         caller already obtained a downline list (e.g. from a previous
    ///         call) and only wants per-member rows.
    function getPositions(address[] calldata addrs) external view returns (Position[] memory out) {
        out = new Position[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            (uint256 c, uint256 g, uint256 n, address r) = ilo.getUserPosition(addrs[i]);
            out[i] = Position({contributed: c, gathMinted: g, nftCount: n, referrer: r});
        }
    }

    /// @notice Combined "give me everything for this address in one call":
    ///         the member's own membership info + ILO position + first page
    ///         of children. Saves the 4-call dance the JS client does today
    ///         when expanding a single node.
    struct MemberDetail {
        uint256 level;
        address referrer;
        uint256 childrenCount;
        address[] children;
        Position position;
    }

    function getMemberDetail(address account, uint256 childrenLimit) external view returns (MemberDetail memory detail) {
        (uint256 lvl, address ref) = membership.members(account);
        detail.level = lvl;
        detail.referrer = ref;
        detail.childrenCount = membership.childrenCountOf(account);

        uint256 take = detail.childrenCount;
        if (childrenLimit > 0 && take > childrenLimit) take = childrenLimit;
        detail.children = membership.childrenRange(account, 0, take);

        (uint256 c, uint256 g, uint256 n, address r) = ilo.getUserPosition(account);
        detail.position = Position({contributed: c, gathMinted: g, nftCount: n, referrer: r});
    }
}
