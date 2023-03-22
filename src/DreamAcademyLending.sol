// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "./DreamOracle.sol";
import "forge-std/console.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

/**
ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
- 이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50%, liquidation threshold는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
- 필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
- 청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
- 실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
 */

contract DreamAcademyLending {
    struct VaultInfo{
        uint256 collateralETH;
        uint256 collateralUSDC;
        uint256 availableBorrowETH2USDC;
        uint256 borrowUSDC;
    }
    uint256 constant LTV = 50;

    address token;
    IPriceOracle oracle;
    mapping(address => VaultInfo) vaults;

    constructor(IPriceOracle _oracle, address _token) {
        token = _token;
        oracle = _oracle;
    }

    function initializeLendingProtocol(address _tokenAddress) external payable{
        IERC20(_tokenAddress).transferFrom(msg.sender, address(this), msg.value);
    }

    /** deposi(입금)
    ETH <-> USDC (2 cases)
    1. _amount만큼 담보로 저장 (ETH: msg.value, USDC: _amount)
    2. 해당 amount로 얼마 빌릴 수 있는지 구하기
    3. VaultInfo update
    */
    function deposit(address _tokenAddress, uint256 _amount) external payable{
        require(_tokenAddress == address(0x0) || _tokenAddress == token, "We do not support!");
        VaultInfo memory tempVault;
        
        if(_tokenAddress == address(0x0)){
            require(msg.value != 0, "error");
            require(msg.value == _amount, "false");
            tempVault.collateralETH += msg.value;
   
        }
        else{
            require(_amount!= 0, "INSUFFICIENT_AMOUNT");
            IERC20(_tokenAddress).transferFrom(msg.sender, address(this), _amount);
            tempVault.collateralUSDC += _amount;
        }
        vaults[msg.sender] = tempVault;
    }


    /** borrow
    1$ pegging -> 1USDC = 1$
    1. msg.sender가 빌릴 수 있는양 계산(잔고x담보ETHxLTV) -> 빌릴 수 있는 양은 빌리려고 하는 양보다 많아야 함
    
    
    */
    function borrow(address _tokenAddress, uint256 _amount) external{
        _update();
        VaultInfo memory tempVault = vaults[msg.sender]; 
        require(tempVault.availableBorrowETH2USDC >= _amount+tempVault.borrowUSDC, "INSUFFICIENT_COLLATERAL_AMOUNT");
        IERC20(token).transfer(msg.sender, _amount);
        tempVault.borrowUSDC += _amount;

        vaults[msg.sender] = tempVault;
        
    }
    function repay(address _tokenAddress, uint256 _amount) external{
        VaultInfo memory tempVault = vaults[msg.sender];
        IERC20(token).transferFrom(msg.sender, address(this), _amount);
        tempVault.borrowUSDC -= _amount;
        vaults[msg.sender] = tempVault;
    }

    function liquidate(address _user, address _tokenAddress, uint256 _amount) external{

    }

    function withdraw(address _tokenAddress, uint256 _amount) external{
        uint256 availableWithdraw =  vaults[msg.sender].borrowUSDC *1e18 / oracle.getPrice(address(0x0)) * LTV / 100;
        VaultInfo memory tempVault = vaults[msg.sender];

        require(tempVault.collateralETH >= _amount, "INSUFFICIENT_AMOUNT");
        require(tempVault.collateralETH - availableWithdraw >= _amount);

        tempVault.collateralETH -= _amount;
        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        require(success, "ERROR");

        vaults[msg.sender] = tempVault;
    }

    function getAccruedSupplyAmount(address _tokenAddress) external returns(uint256){
        return 1;
    }

    function _update() private returns(uint256) {
        vaults[msg.sender].availableBorrowETH2USDC = vaults[msg.sender].collateralETH * oracle.getPrice(address(0x0)) * LTV / (100*1e18) ;
    }

}