
    enum YieldMode {
        AUTOMATIC,
        VOID,
        CLAIMABLE
    }
interface IERC20Rebasing {

    function configure(YieldMode) external returns (uint256);

    function claim(
        address recipient,
        uint256 amount
    ) external returns (uint256);

    function getClaimableAmount(
        address account
    ) external view returns (uint256);

    function price() external view returns (uint256);
    function sharePrice() external view returns (uint256);
}
