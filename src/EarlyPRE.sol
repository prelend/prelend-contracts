import "openzeppelin/token/ERC20/ERC20.sol";

contract EarlyPRE is ERC20 {
    constructor() ERC20("Early PreLend", "PRE") {
        _mint(msg.sender, 10000000e18);
    }
}
