interface IRebaseTracker {
    function catchUp() external returns (uint256, uint256);
    function peek() external view returns (uint256, uint256);
}
