// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/IFountainV1.sol";

/**

@title Fountain

Create a Money pool (MP) that'll be used to sustain your project, and specify what its sustainability target is.
Maybe your project is providing a service or public good, maybe it's being a YouTuber, engineer, or artist -- or anything else.
Anyone with your address can help sustain your project, and once you're sustainable any additional contributions are redistributed back your sustainers.

Each Money pool is like a tier of the fountain, and the predefined cost to pursue the project is like the bounds of that tier's pool.

An address can only be associated with one active Money pool at a time, as well as a mutable one queued up for when the active Money pool expires.
If a Money pool expires without one queued, the current one will be cloned and sustainments at that time will be allocated to it.
It's impossible for a Money pool's sustainability or duration to be changed once there has been a sustainment made to it.
Any attempts to do so will just create/update the message sender's queued MP.

You can collect funds of yours from the sustainers pool (where Money pool surplus is distributed) or from the sustainability pool (where Money pool sustainments are kept) at anytime.

Future versions will introduce Money pool dependencies so that your project's surplus can get redistributed to the MP of projects it is composed of before reaching sustainers.

The basin of the Fountain should always be the sustainers of projects.

*/

/// @notice The contract managing the state of all Money pools.
contract FountainV1 is IFountainV1 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Possible states that a Money pool may be in
    /// @dev Money pool's are immutable once the Money pool is active.
    enum MpState {Upcoming, Active, Redistributing}

    /// @notice The Money pool structure represents a project stewarded by an address, and accounts for which addresses have helped sustain the project.
    struct MoneyPool {
        // The address who defined this Money pool and who has access to its sustainments.
        address owner;
        // The token that this Money pool can be funded with.
        IERC20 want;
        // The amount that represents sustainability for this Money pool.
        uint256 target;
        // The running amount that's been contributed to sustaining this Money pool.
        uint256 total;
        // The time when this Money pool will become active.
        uint256 start;
        // The number of seconds until this Money pool's surplus is redistributed.
        uint256 duration;
        // The amount of available funds that have been tapped by the owner.
        uint256 tapped;
        // Helper to verify this Money pool exists.
        bool exists;
        // Indicates if surplus funds have been redistributed for each sustainer address.
        mapping(address => bool) hasRedistributed;
        // The amount each address has contributed to sustaining this Money pool.
        mapping(address => uint256) sustainments;
        // The Money pool's version.
        uint8 version;
    }

    // Wrap the sustain and collect transactions in unique locks to prevent reentrency.
    uint8 private lock1 = 1;
    uint8 private lock2 = 1;
    uint8 private lock3 = 1;
    modifier lockSustain() {
        require(lock1 == 1, "Fountain: sustainment locked");
        lock1 = 0;
        _;
        lock1 = 1;
    }
    modifier lockCollectRedistribution() {
        require(lock2 == 1, "Fountain: collect redistribution locked");
        lock2 = 0;
        _;
        lock2 = 1;
    }
    modifier lockCollectSustainment() {
        require(lock3 == 1, "Fountain: collect sustainment locked");
        lock3 = 0;
        _;
        lock3 = 1;
    }

    // --- private properties --- //

    // The official record of all Money pools ever created
    mapping(uint256 => MoneyPool) private mps;

    // List of owners sustained by each sustainer
    mapping(address => address[]) private sustainedOwners;

    // Map of whether or not an address has sustained another owner.
    mapping(address => mapping(address => bool)) private sustainedOwnerTracker;

    // --- public properties --- //

    /// @notice A mapping from Money pool id's the the id of the previous Money pool for the same owner.
    mapping(uint256 => uint256) public override previousMpIds;

    /// @notice The latest Money pool for each owner address
    mapping(address => uint256) public override latestMpIds;

    // The total number of Money pools created, which is used for issuing Money pool IDs.
    // Money pools should have an ID > 0.
    uint256 public override mpCount;

    // The contract currently only supports sustainments in dai.
    IERC20 public dai;

    // --- events --- //

    /// This event should trigger when a Money pool is first initialized.
    event InitializeMp(uint256 indexed mpId, address indexed owner);

    // This event should trigger when a Money pool's state changes to active.
    event ActivateMp(
        uint256 indexed mpId,
        address indexed owner,
        uint256 indexed target,
        uint256 duration,
        IERC20 want
    );

    /// This event should trigger when a Money pool is configured.
    event ConfigureMp(
        uint256 indexed mpId,
        address indexed owner,
        uint256 indexed target,
        uint256 duration,
        IERC20 want
    );

    /// This event should trigger when a Money pool is sustained.
    event SustainMp(
        uint256 indexed mpId,
        address indexed owner,
        address indexed beneficiary,
        address sustainer,
        uint256 amount
    );

    /// This event should trigger when redistributions are collected.
    event CollectRedistributions(address indexed sustainer, uint256 amount);

    /// This event should trigger when sustainments are collected.
    event CollectSustainments(
        uint256 indexed mpId,
        address indexed owner,
        uint256 amount,
        IERC20 want
    );

    // --- external views --- //

    /// @dev The properties of the given Money pool.
    /// @param _mpId The ID of the Money pool to get the properties of.
    /// @return id The ID of the Money pool.
    /// @return want The token the Money pool wants.
    /// @return target The amount of the want token this Money pool is targeting.
    /// @return start The time when this Money pool started.
    /// @return duration The duration of this Money pool measured in seconds.
    /// @return total The total amount passed through the Money pool. Returns 0 if the Money pool isn't owned by the message sender.
    function getMp(uint256 _mpId)
        external
        view
        override
        returns (
            uint256 id,
            IERC20 want,
            uint256 target,
            uint256 start,
            uint256 duration,
            uint256 total
        )
    {
        return _mpProperties(_mpId);
    }

    /// @dev The Money pool that's next up for an owner.
    /// @param _owner The owner of the Money pool being looked for.
    /// @return id The ID of the Money pool.
    /// @return want The token the Money pool wants.
    /// @return target The amount of the want token this Money pool is targeting.
    /// @return start The time when this Money pool started.
    /// @return duration The duration of this Money pool measured in seconds.
    /// @return total The total amount passed through the Money pool. Returns 0 if the Money pool isn't owned by the message sender.
    function getUpcomingMp(address _owner)
        external
        view
        override
        returns (
            uint256 id,
            IERC20 want,
            uint256 target,
            uint256 start,
            uint256 duration,
            uint256 total
        )
    {
        return _mpProperties(_upcomingMpId(_owner));
    }

    /// @dev The currently active Money pool for an owner.
    /// @param _owner The owner of the money pool being looked for.
    /// @return id The ID of the Money pool.
    /// @return want The token the Money pool wants.
    /// @return target The amount of the want token this Money pool is targeting.
    /// @return start The time when this Money pool started.
    /// @return duration The duration of this Money pool measured in seconds.
    /// @return total The total amount passed through the Money pool. Returns 0 if the Money pool isn't owned by the message sender.
    function getActiveMp(address _owner)
        external
        view
        override
        returns (
            uint256 id,
            IERC20 want,
            uint256 target,
            uint256 start,
            uint256 duration,
            uint256 total
        )
    {
        return _mpProperties(_activeMpId(_owner));
    }

    /// @dev The amount of sustainments accessible.
    /// @param _mpId The ID of the Money pool to get the balance for.
    /// @return amount The amount.
    function getSustainmentBalance(uint256 _mpId)
        external
        view
        override
        returns (uint256)
    {
        MoneyPool storage _mp = mps[_mpId];
        return _tappableAmount(_mp);
    }

    /// @dev The amount of sustainments in a Money pool that were contributed by the given address.
    /// @param _mpId The ID of the Money pool to get a contribution for.
    /// @param _sustainer The address of the sustainer to get an amount for.
    /// @return amount The amount.
    function getSustainment(uint256 _mpId, address _sustainer)
        external
        view
        override
        returns (uint256)
    {
        return mps[_mpId].sustainments[_sustainer];
    }

    /// @dev The amount of redistribution in a Money pool that can be claimed by the given address.
    /// @param _mpId The ID of the Money pool to get a redistribution amount for.
    /// @param _sustainer The address of the sustainer to get an amount for.
    /// @return amount The amount.
    function getTrackedRedistribution(uint256 _mpId, address _sustainer)
        external
        view
        override
        returns (uint256)
    {
        return _trackedRedistribution(_mpId, _sustainer);
    }

    // --- external transactions --- //

    constructor(IERC20 _dai) public {
        dai = _dai;
        mpCount = 0;
    }

    /// @dev Configures the sustainability target and duration of the sender's current Money pool if it hasn't yet received sustainments, or
    /// @dev sets the properties of the Money pool that will take effect once the current Money pool expires.
    /// @param _target The sustainability target to set.
    /// @param _duration The duration to set, measured in seconds.
    /// @param _want The token that the Money pool wants.
    /// @return mpId The ID of the Money pool that was successfully configured.
    function configureMp(
        uint256 _target,
        uint256 _duration,
        IERC20 _want
    ) external override returns (uint256) {
        require(
            _duration >= 1,
            "Fountain::configureMp: A Money Pool must be at least one day long"
        );
        require(
            _target > 0,
            "Fountain::configureMp: A Money Pool target must be a positive number"
        );

        uint256 _mpId = _mpIdToConfigure(msg.sender);
        MoneyPool storage _mp = mps[_mpId];
        _mp.target = _target;
        _mp.duration = _duration;
        _mp.want = _want;

        if (previousMpIds[_mpId] == 0) emit InitializeMp(mpCount, msg.sender);
        emit ConfigureMp(mpCount, msg.sender, _target, _duration, _want);

        return _mpId;
    }

    /// @dev Overloaded from above with the addition of:
    /// @param _owner The owner of the Money pool to sustain.
    /// @param _amount Amount of sustainment.
    /// @param _beneficiary The address to associate with this sustainment. This is usually mes.sender, but can be something else if the sender is making this sustainment on the beneficiary's behalf.
    /// @return mpId The ID of the Money pool that was successfully sustained.
    function sustain(
        address _owner,
        uint256 _amount,
        address _beneficiary
    ) external override returns (uint256) {
        return _sustain(_owner, _amount, _beneficiary);
    }

    /// @dev A message sender can collect what's been redistributed to it by Money pools once they have expired.
    /// @return amount If the collecting was a success.
    function collectAllRedistributions()
        external
        override
        lockCollectRedistribution
        returns (uint256)
    {
        // Iterate over all of sender's sustained addresses to make sure
        // redistribution has completed for all redistributable Money pools
        uint256 _amount =
            _redistributeAmount(msg.sender, sustainedOwners[msg.sender]);

        _performCollectRedistributions(msg.sender, _amount);
        return _amount;
    }

    /// @dev A message sender can collect what's been redistributed to it by a specific Money pool once it's expired.
    /// @param _owner The Money pool owner to collect from.
    /// @return success If the collecting was a success.
    function collectRedistributionsFromOwner(address _owner)
        external
        override
        lockCollectRedistribution
        returns (uint256)
    {
        uint256 _amount = _redistributeAmount(msg.sender, _owner);
        _performCollectRedistributions(msg.sender, _amount);
        return _amount;
    }

    /// @dev A message sender can collect what's been redistributed to it by specific Money pools once they have expired.
    /// @param _owners The Money pools owners to collect from.
    /// @return success If the collecting was a success.
    function collectRedistributionsFromOwners(address[] calldata _owners)
        external
        override
        lockCollectRedistribution
        returns (uint256)
    {
        uint256 _amount = _redistributeAmount(msg.sender, _owners);
        _performCollectRedistributions(msg.sender, _amount);
        return _amount;
    }

    /// @dev A message sender can collect specific funds that have been used to sustain it's Money pools.
    /// @param _mpId The ID of the Money pool to tap.
    /// @param _amount The amount to tap.
    /// @return success If the collecting was a success.
    function collectSustainments(uint256 _mpId, uint256 _amount)
        external
        override
        lockCollectSustainment
        returns (bool)
    {
        MoneyPool storage _mp = mps[_mpId];
        require(
            _mp.owner == msg.sender,
            "Fountain::collectSustainments: Money pools can only be tapped by their owner"
        );
        _tap(_mp, _amount);

        _mp.want.safeTransfer(msg.sender, _amount);
        emit CollectSustainments(_mpId, msg.sender, _amount, _mp.want);

        return true;
    }

    // --- private --- //

    /// @dev Contribute a specified amount to the sustainability of the specified address's active Money pool.
    /// @dev If the amount results in surplus, redistribute the surplus proportionally to sustainers of the Money pool.
    /// @param _owner The owner of the Money pool to sustain.
    /// @param _amount Amount of sustainment.
    /// @param _beneficiary The address to associate with this sustainment. The mes.sender is making this sustainment on the beneficiary's behalf.
    /// @return mpId The ID of the Money pool that was successfully sustained.
    function _sustain(
        address _owner,
        uint256 _amount,
        address _beneficiary
    ) private lockSustain returns (uint256) {
        require(
            _amount > 0,
            "Fountain::sustain: The sustainment amount should be positive"
        );

        // Find the Money pool that this sustainment should go to.
        uint256 _mpId = _mpIdToSustain(_owner);
        MoneyPool storage _mp = mps[_mpId];

        _mp.want.safeTransferFrom(msg.sender, address(this), _amount);

        // Increment the sustainments to the Money pool made by the message sender.
        _mp.sustainments[_beneficiary] = _mp.sustainments[_beneficiary].add(
            _amount
        );

        //If surplus, buy water.
        //Mint root(water) and distribute to LPs.

        if (_mp.total == 0)
            // Emit an event since since is the first sustainment being made towards this Money pool.
            emit ActivateMp(
                mpCount,
                _mp.owner,
                _mp.target,
                _mp.duration,
                _mp.want
            );

        // Increment the total amount contributed to the sustainment of the Money pool.
        _mp.total = _mp.total.add(_amount);

        // Add this address to the sustainer's list of sustained addresses
        if (sustainedOwnerTracker[_beneficiary][msg.sender] == false) {
            sustainedOwners[_beneficiary].push(msg.sender);
            sustainedOwnerTracker[_beneficiary][msg.sender] == true;
        }

        // Emit events.
        emit SustainMp(_mpId, _mp.owner, _beneficiary, msg.sender, _amount);
        return _mpId;
    }

    /// @dev The properties of the given Money pool.
    /// @param _mpId The ID of the Money pool to get the properties of.
    /// @return id The ID of the Money pool.
    /// @return want The token the Money pool wants.
    /// @return target The amount of the want token this Money pool is targeting.
    /// @return start The time when this Money pool started.
    /// @return duration The duration of this Money pool, measured in seconds.
    /// @return total The total amount passed through the Money pool. Returns 0 if the Money pool isn't owned by the message sender.
    function _mpProperties(uint256 _mpId)
        private
        view
        returns (
            uint256,
            IERC20,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        MoneyPool memory _mp = mps[_mpId];
        require(_mp.exists, "Fountain::_mpProperties: Money pool not found");

        return (
            _mpId,
            _mp.want,
            _mp.target,
            _mp.start,
            _mp.duration,
            _mp.total
        );
    }

    /// @dev Executes the collection of redistributed funds.
    /// @param _sustainer The sustainer address to redistribute to.
    /// @param _amount The amount to collect.
    function _performCollectRedistributions(address _sustainer, uint256 _amount)
        private
    {
        dai.safeTransfer(_sustainer, _amount);
        emit CollectRedistributions(_sustainer, _amount);
    }

    /// @dev The sustainability of a Money pool cannot be updated if there have been sustainments made to it.
    /// @param _owner The address who owns the Money pool to look for.
    /// @return id The resulting Money pool's id.
    function _mpIdToConfigure(address _owner) private returns (uint256 id) {
        // Allow active moneyPool to be updated if it has no sustainments
        uint256 _mpId = _activeMpId(_owner);
        if (_mpId != 0 && mps[_mpId].total == 0) return _mpId;

        // Cannot update active moneyPool, check if there is a upcoming moneyPool
        _mpId = _upcomingMpId(_owner);
        if (_mpId != 0) return _mpId;

        // No upcoming moneyPool found, clone the latest moneyPool
        _mpId = latestMpIds[_owner];

        if (_mpId != 0) return _createMpFromId(_mpId, now);

        _mpId = _initMp(_owner);
        MoneyPool storage _mp = mps[_mpId];
        _mp.start = now;

        return _mpId;
    }

    /// @dev Only active Money pools can be sustained.
    /// @param _owner The address who owns the Money pool to look for.
    /// @return id The resulting Money pool's id.
    function _mpIdToSustain(address _owner) private returns (uint256) {
        // Check if there is an active moneyPool
        uint256 _mpId = _activeMpId(_owner);
        if (_mpId != 0) return _mpId;

        // No active moneyPool found, check if there is an upcoming moneyPool
        _mpId = _upcomingMpId(_owner);
        if (_mpId != 0) return _mpId;

        // No upcoming moneyPool found, clone the latest moneyPool
        _mpId = latestMpIds[_owner];

        require(_mpId > 0, "Fountain::mpIdToSustain: Money pool not found");

        MoneyPool memory _latestMp = mps[_mpId];
        // Use a start date that's a multiple of the duration.
        // This creates the effect that there have been scheduled Money pools ever since the `latest`, even if `latest` is a long time in the past.
        uint256 _start =
            _determineModuloStart(
                _latestMp.start.add(_latestMp.duration),
                _latestMp.duration
            );

        return _createMpFromId(_mpId, _start);
    }

    /// @dev Take the amount that should be redistributed to the given sustainer by the given owner's Money pools.
    /// @param _sustainer The sustainer address to redistribute to.
    /// @param _owners The Money pool owners to redistribute from.
    /// @return _amount The amount that has been redistributed.
    function _redistributeAmount(address _sustainer, address[] memory _owners)
        private
        returns (uint256)
    {
        uint256 _amount = 0;
        for (uint256 i = 0; i < _owners.length; i++)
            _amount = _amount.add(_redistributeAmount(_sustainer, _owners[i]));

        return _amount;
    }

    /// @dev Take the amount that should be redistributed to the given sustainer by the given owner's Money pools.
    /// @param _sustainer The sustainer address to redistribute to.
    /// @param _owner The Money pool owner to redistribute from.
    /// @return _amount The amount that has been redistributed.
    function _redistributeAmount(address _sustainer, address _owner)
        private
        returns (uint256)
    {
        uint256 _amount = 0;
        uint256 _mpId = latestMpIds[_owner];
        require(
            _mpId > 0,
            "Fountain::_getRedistributionAmount: Money Pool not found"
        );
        MoneyPool storage _mp = mps[_mpId];

        // Iterate through all Money pools for this owner address. For each iteration,
        // if the Money pool has a state of redistributing and it has not yet
        // been redistributed for the current sustainer, then process the
        // redistribution. Iterate until a Money pool is found that has already
        // been redistributed for this sustainer. This logic should skip Active
        // and Upcoming Money pools.
        // Short circuits by testing `moneyPool.hasRedistributed` to limit number
        // of iterations since all previous Money pools must have already been
        // redistributed.
        while (_mpId > 0 && !_mp.hasRedistributed[_sustainer]) {
            if (_state(_mpId) == MpState.Redistributing) {
                _amount = _amount.add(
                    _trackedRedistribution(_mpId, _sustainer)
                );
                _mp.hasRedistributed[_sustainer] = true;
            }
            _mpId = previousMpIds[_mpId];
            _mp = mps[_mpId];
        }

        return _amount;
    }

    /// @dev Take the amount that should be redistributed to the given sustainer by the given owner's Money pools.
    /// @param _mp The Money pool to tap.
    /// @param _amount The amount to tap.
    function _tap(MoneyPool storage _mp, uint256 _amount) private {
        uint256 _mpAmountTappable = _tappableAmount(_mp);
        require(
            _mpAmountTappable >= _amount,
            "Fountain::_tap: Not enough to tap"
        );
        _mp.tapped = _mp.tapped.add(_amount);
    }

    /// @dev Returns a copy of the given Money pool with reset sustainments.
    /// @param _baseMpId The ID of the Money pool to base the new Money pool on.
    /// @param _start The start date to use for the new Money pool.
    /// @return id The new Money pool's id.
    function _createMpFromId(uint256 _baseMpId, uint256 _start)
        private
        returns (uint256)
    {
        MoneyPool memory _baseMp = mps[_baseMpId];
        uint256 _mpId = _initMp(_baseMp.owner);
        MoneyPool storage _mp = mps[_mpId];

        _mp.target = _baseMp.target;
        _mp.duration = _baseMp.duration;
        _mp.want = _baseMp.want;

        _mp.start = _start;

        return _mpId;
    }

    /// @notice Initializes a Money pool to be sustained for the sending address.
    /// @param _owner The owner of the money pool being initialized.
    /// @return id The initialized Money pool's ID.
    function _initMp(address _owner) private returns (uint256) {
        mpCount++;
        MoneyPool storage _newMp = mps[mpCount];
        _newMp.owner = _owner;
        _newMp.total = 0;
        _newMp.tapped = 0;
        _newMp.exists = true;
        _newMp.version = 1;

        previousMpIds[mpCount] = latestMpIds[_owner];
        latestMpIds[_owner] = mpCount;

        return mpCount;
    }

    /// @dev The amount of redistribution in a Money pool that can be claimed by the given address.
    /// @param _mpId The ID of the Money pool to get a redistribution amount for.
    /// @param _sustainer The address of the sustainer to get an amount for.
    /// @return amount The amount.
    function _trackedRedistribution(uint256 _mpId, address _sustainer)
        private
        view
        returns (uint256)
    {
        MoneyPool storage _mp = mps[_mpId];

        // Return 0 if there's no surplus.
        if (!_mp.exists || _mp.target >= _mp.total) return 0;

        uint256 surplus = _mp.total.sub(_mp.target);

        // Calculate their share of the sustainment for the the given sustainer.
        // allocate a proportional share of the surplus, overwriting any previous value.
        uint256 _proportionOfTotal =
            _mp.sustainments[_sustainer].div(_mp.total);

        return surplus.mul(_proportionOfTotal);
    }

    /// @dev The currently active Money pool for an owner.
    /// @param _owner The owner of the money pool being looked for.
    /// @return id The active Money pool's ID.
    function _activeMpId(address _owner) private view returns (uint256) {
        uint256 _mpId = latestMpIds[_owner];
        if (_mpId == 0) return 0;

        // An Active moneyPool must be either the latest moneyPool or the
        // moneyPool immediately before it.
        if (_state(_mpId) == MpState.Active) return _mpId;

        _mpId = previousMpIds[_mpId];
        if (_mpId > 0 && _state(_mpId) == MpState.Active) return _mpId;

        return 0;
    }

    /// @dev The Money pool that's next up for an owner.
    /// @param _owner The owner of the money pool being looked for.
    /// @return id The ID of the upcoming Money pool.
    function _upcomingMpId(address _owner) private view returns (uint256) {
        uint256 _mpId = latestMpIds[_owner];
        if (_mpId == 0) return 0;
        // There is no upcoming Money pool if the latest Money pool is not upcoming
        if (_state(_mpId) != MpState.Upcoming) return 0;
        return _mpId;
    }

    /// @dev The state the Money pool for the given ID is in.
    /// @param _mpId The ID of the Money pool to get the state of.
    /// @return state The state.
    function _state(uint256 _mpId) private view returns (MpState) {
        require(
            mpCount >= _mpId && _mpId > 0,
            "Fountain::_state: Invalid Money pool ID"
        );
        MoneyPool memory _mp = mps[_mpId];
        require(_mp.exists, "Fountain::_state: Invalid Money Pool");

        if (_hasMpExpired(_mp)) return MpState.Redistributing;
        if (_hasMpStarted(_mp)) return MpState.Active;
        return MpState.Upcoming;
    }

    /// @dev Check to see if the given Money pool has started.
    /// @param _mp The Money pool to check.
    /// @return hasStarted The boolean result.
    function _hasMpStarted(MoneyPool memory _mp) private view returns (bool) {
        return now >= _mp.start;
    }

    /// @dev Check to see if the given MoneyPool has expired.
    /// @param _mp The Money pool to check.
    /// @return hasExpired The boolean result.
    function _hasMpExpired(MoneyPool memory _mp) private view returns (bool) {
        return now > _mp.start.add(_mp.duration);
    }

    /// @dev Returns the amount available for the given Money pool's owner to tap in to.
    /// @param _mp The Money pool to make the calculation for.
    /// @return The resulting amount.
    function _tappableAmount(MoneyPool storage _mp)
        private
        view
        returns (uint256)
    {
        return
            (_mp.target > _mp.total ? _mp.total : _mp.target).sub(_mp.tapped);
    }

    /// @dev Returns the date that is the nearest multiple of duration from oldEnd.
    /// @param _oldEnd The most recent end date to calculate from.
    /// @param _duration The duration to use for the calculation.
    /// @return start The date.
    function _determineModuloStart(uint256 _oldEnd, uint256 _duration)
        private
        view
        returns (uint256)
    {
        // Use the old end if the current time is still within the duration.
        if (_oldEnd.add(_duration) > now) return _oldEnd;
        // Otherwise, use the closest multiple of the duration from the old end.
        uint256 _distanceToStart = (now.sub(_oldEnd)).mod(_duration);
        return now.sub(_distanceToStart);
    }
}
