// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  SimpleENS (governed v4)
 * @notice Mini-ENS con:
 *         • Registro inicial 0.0005 ETH   (modifiable)
 *         • Renovación      0.0001 ETH/mes (modifiable)
 *         • 60 d de gracia, pujas con una sola bestBid, refunds automáticos
 *         • Gobernanza on-chain: transferir `ownership` a un Governor / Timelock
 *         • ReentrancyGuard, pull-payments, errores custom
 */

import {Ownable}         from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Address}         from "@openzeppelin/contracts/utils/Address.sol";

contract SimpleENS is Ownable, ReentrancyGuard {
    using Address for address payable;

    /*────────────────── Config gobernable ──────────────────*/

    uint256 public initialFee = 0.0005 ether;   // registro 1 año
    uint256 public renewFeePM = 0.0001 ether;   // renovación / mes

    uint64  public constant TERM         = 365 days;
    uint64  public constant GRACE_PERIOD = 60 days;
    uint8   public constant MIN_NAME_LEN = 3;

    /*───────────────────── Storage ─────────────────────────*/

    struct Bid {
        address bidder;
        uint256 amount;
        uint64  id;
    }

    struct DomainInfo {
        address owner;
        address target;
        uint64  expiry;
        Bid     bestBid;     // sólo la mejor oferta
    }

    mapping(bytes32 => DomainInfo) private _domains;
    uint64 private _bidCounter;

    /*──────────────────── Events / Errors ───────────────────*/

    event Registered  (string indexed domain, address owner, uint64 expiry);
    event Renewed     (string indexed domain, uint64 newExpiry);
    event ResolverSet (string indexed domain, address target);

    event BidPlaced   (string indexed domain, uint64 bidId, address bidder, uint256 amount);
    event BidAccepted (string indexed domain, uint64 bidId, address newOwner, uint256 amount);
    event BidRejected (string indexed domain, uint64 bidId);

    event FeesUpdated (uint256 newInitial, uint256 newRenewPM);

    error NameTooShort();
    error DomainTaken();
    error NotDomainOwner();
    error FeeTooLow(uint256 required);
    error OutsideGrace();
    error NoActiveBid();

    /*───────────────── Name helpers ────────────────────────*/

    function _hash(string memory name) internal pure returns (bytes32) {
        bytes memory b = bytes(name);
        if (b.length < MIN_NAME_LEN) revert NameTooShort();
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 65 && c <= 90) b[i] = bytes1(c + 32);        // A-Z → a-z
        }
        return keccak256(b);
    }

    function _isExpired(bytes32 node) internal view returns (bool) {
        return _domains[node].expiry < block.timestamp;
    }

    function _isFree(bytes32 node) internal view returns (bool) {
        DomainInfo storage d = _domains[node];
        if (d.owner == address(0)) return true;
        return _isExpired(node) && block.timestamp > d.expiry + GRACE_PERIOD;
    }

    /*──────────────── Gobernanza de tarifas ────────────────*/

    function setFees(uint256 newInitial, uint256 newRenewPM) external onlyOwner {
        require(newInitial > 0 && newRenewPM > 0, "fee=0");
        initialFee = newInitial;
        renewFeePM = newRenewPM;
        emit FeesUpdated(newInitial, newRenewPM);
    }

    /*──────────────── Registro ─────────────────────────────*/

    function register(string calldata name, address target)
        external
        payable
        nonReentrant
    {
        if (msg.value < initialFee) revert FeeTooLow(initialFee);
        bytes32 node = _hash(name);
        if (!_isFree(node)) revert DomainTaken();

        _domains[node] = DomainInfo({
            owner:   msg.sender,
            target:  target,
            expiry:  uint64(block.timestamp + TERM),
            bestBid: Bid(address(0), 0, 0)
        });

        emit Registered(name, msg.sender, uint64(block.timestamp + TERM));
        _refund(msg.value - initialFee);
    }

    /*──────────────── Renovación ───────────────────────────*/

    function renew(string calldata name, uint8 months_)
        external
        payable
        nonReentrant
    {
        bytes32 node = _hash(name);
        DomainInfo storage d = _domains[node];
        if (d.owner != msg.sender) revert NotDomainOwner();
        if (block.timestamp > d.expiry + GRACE_PERIOD) revert OutsideGrace();

        uint256 required = uint256(months_) * renewFeePM;
        if (msg.value < required) revert FeeTooLow(required);

        d.expiry += uint64(months_) * 30 days;
        emit Renewed(name, d.expiry);
        _refund(msg.value - required);
    }

    /*──────────────── Resolver ─────────────────────────────*/

    function setResolver(string calldata name, address newTarget) external {
        bytes32 node = _hash(name);
        if (_domains[node].owner != msg.sender) revert NotDomainOwner();
        _domains[node].target = newTarget;
        emit ResolverSet(name, newTarget);
    }

    function resolve(string calldata name) external view returns (address) {
        return _domains[_hash(name)].target;
    }

    /*──────────────── Pujas ────────────────────────────────*/

    function placeBid(string calldata name) external payable nonReentrant {
        bytes32 node = _hash(name);
        DomainInfo storage d = _domains[node];
        if (d.owner == address(0)) revert DomainTaken();
        if (d.owner == msg.sender) revert();
        if (msg.value <= d.bestBid.amount) revert FeeTooLow(d.bestBid.amount + 1);

        // reembolsa la oferta anterior
        if (d.bestBid.amount > 0) payable(d.bestBid.bidder).sendValue(d.bestBid.amount);

        d.bestBid = Bid({bidder: msg.sender, amount: msg.value, id: ++_bidCounter});
        emit BidPlaced(name, d.bestBid.id, msg.sender, msg.value);
    }

    function acceptBid(string calldata name) external nonReentrant {
        bytes32 node = _hash(name);
        DomainInfo storage d = _domains[node];
        if (d.owner != msg.sender) revert NotDomainOwner();
        if (d.bestBid.amount == 0) revert NoActiveBid();

        address prevOwner = d.owner;
        Bid    memory bid = d.bestBid;

        d.owner  = bid.bidder;
        d.expiry = uint64(block.timestamp + TERM);
        delete d.bestBid;

        payable(prevOwner).sendValue(bid.amount);
        emit BidAccepted(name, bid.id, bid.bidder, bid.amount);
    }

    function rejectBid(string calldata name) external nonReentrant {
        bytes32 node = _hash(name);
        DomainInfo storage d = _domains[node];
        if (d.owner != msg.sender) revert NotDomainOwner();
        if (d.bestBid.amount == 0) revert NoActiveBid();

        payable(d.bestBid.bidder).sendValue(d.bestBid.amount);
        emit BidRejected(name, d.bestBid.id);
        delete d.bestBid;
    }

    /*──────────────── Info view ────────────────────────────*/

    function domainInfo(string calldata name) external view returns (
        address owner_, address target_, uint64 expiry_,
        uint256 bestBid_, address bidder_, uint64 bidId_
    ) {
        DomainInfo storage d = _domains[_hash(name)];
        return (d.owner, d.target, d.expiry,
                d.bestBid.amount, d.bestBid.bidder, d.bestBid.id);
    }

    /*──────────────── Treasury ─────────────────────────────*/

    function withdraw(address payable to) external onlyOwner {
        to.sendValue(address(this).balance);
    }

    /*──────────────── Utilidades internas ─────────────────*/

    function _refund(uint256 excess) private {
        if (excess > 0) payable(msg.sender).sendValue(excess);
    }
}
