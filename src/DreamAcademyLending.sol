// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
import "./DreamOracle.sol";
import "forge-std/console.sol";
import "./ABDKMath64x64.sol";


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

contract DreamAcademyLending{
    struct LenderVault{
        uint256 depositUSDC;
        uint256 depositBlockNumber;
        uint256 rewards;
    }
    struct BorrowerVault{
        uint256 collateralETH;
        uint256 availableBorrowETH2USDC;
        uint256 borrowUSDC;
        uint256 borrowBlockNumber;
    }
    uint256 constant LTV = 50;
    uint256 constant LT = 75;
    uint256 constant ONE_DAY_BLOCKS_TIME = 86400;
    uint256 constant ONE_DAY_BLOCKS = 7200;
    uint256 constant ONE_BLOCK_SEC = 12;
    //uint256 constant INTEREST_RATE = 1000000011568290959081926677;
    uint256 constant INTEREST_RATE =138819500341472218972641565;

    uint256 totalBorrowUSDC;
    uint256 totalDepositUSDC;
    uint256 totalUSDCUpdate;


    address token;
    IPriceOracle oracle;
    mapping(address => LenderVault) lenderVaults;
    mapping(address => BorrowerVault) borrowerVaults;

    constructor(IPriceOracle _oracle, address _token) {
        token = _token;
        oracle = _oracle;
    }


    function initializeLendingProtocol(address _tokenAddress) external payable{
        IERC20(_tokenAddress).transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address _tokenAddress, uint256 _amount) external payable{
        
        require(_tokenAddress == address(0x0) || _tokenAddress == token, "We do not support!");
        LenderVault memory lender = lenderVaults[msg.sender]; 
        BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
        
        if(_tokenAddress == address(0x0)){ 
            require(msg.value != 0, "error");
            require(msg.value == _amount, "false");
            borrower.collateralETH += msg.value;
   
        }
        else{ 
            require(_amount > 0, "INSUFFICIENT_AMOUNT");
            require(IERC20(_tokenAddress).balanceOf(msg.sender) >= _amount, "INSUFFICIENT_DEPOSIT_AMOUNT");
            _depositInterest();
            IERC20(_tokenAddress).transferFrom(msg.sender, address(this), _amount);
            lender.depositUSDC += _amount;
            totalDepositUSDC += _amount;
            console.log("1. lender.depositUSDC", lender.depositUSDC);

            lender.depositBlockNumber = block.number;
            totalDepositUSDC = block.number;
        }
        lenderVaults[msg.sender] = lender;
        borrowerVaults[msg.sender] = borrower;
    }

    function borrow(address _tokenAddress, uint256 _amount) external{
        _borrowInterest(_tokenAddress);

        BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
        borrower.availableBorrowETH2USDC = borrower.collateralETH * oracle.getPrice(address(0x0)) * LTV / (100*oracle.getPrice(address(_tokenAddress))) - borrower.borrowUSDC ;
        require(borrower.availableBorrowETH2USDC >= _amount, "INSUFFICIENT_COLLATERAL_AMOUNT");

        borrower.borrowUSDC += _amount;
        totalBorrowUSDC += _amount;
        IERC20(token).transfer(msg.sender, _amount);
        
        borrowerVaults[msg.sender] = borrower;
    }

    function repay(address _tokenAddress, uint256 _amount) external{
        _borrowInterest(_tokenAddress);

        BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
        require(borrower.borrowUSDC >= _amount, "INSUFFICIENT_REPAY_AMOUNT");
        require(IERC20(_tokenAddress).balanceOf(msg.sender) >= _amount, "INSUFFICIENT_REPAY_AMOUNT");

        borrower.borrowUSDC -= _amount;
        totalBorrowUSDC -= _amount;
        IERC20(token).transferFrom(msg.sender, address(this), _amount);

        borrowerVaults[msg.sender] = borrower;
    }

    function liquidate(address _user, address _tokenAddress, uint256 _amount) external{
        _borrowInterest(_tokenAddress);

        BorrowerVault memory borrower = borrowerVaults[_user]; 

        require(borrower.borrowUSDC >= _amount, "INSUFFICIENT_LIQUIDATE_AMOUNT");
       
        uint price = borrower.collateralETH * oracle.getPrice(address(0x0))/oracle.getPrice(_tokenAddress) * LT/100;
        require(borrower.borrowUSDC > price, "INSUFFICIENT_LIQUIDATE_AMOUNT");
        require(_amount == borrower.borrowUSDC/4 || borrower.borrowUSDC < 100 ether, "INSUFFICIENT_LIQUIDATE_AMOUNT");
        
        borrower.borrowUSDC -= _amount;
        totalBorrowUSDC -= _amount;

        borrower.collateralETH -= _amount * oracle.getPrice(_tokenAddress)/oracle.getPrice(address(0x0));
        borrowerVaults[_user] = borrower;

    }

    function withdraw(address _tokenAddress, uint256 _amount) external {
        _borrowInterest(_tokenAddress);
        _depositInterest();
        totalDepositUSDC = block.number;
        LenderVault memory lender = lenderVaults[msg.sender]; 
        BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
        
        
        if(_tokenAddress == address(0)){
            require(borrower.collateralETH >= _amount, "INSUFFICIENT_AMOUNT");
            require(address(this).balance >= _amount, "INSUFFICIENT_AMOUNT");

            uint256 availableWithdrawETH =  borrower.borrowUSDC * oracle.getPrice(address(token)) / (oracle.getPrice(address(0x0)));
            require((borrower.collateralETH - _amount) * LT / 100  >= availableWithdrawETH, "CANNOT_WITHDRAW");
            borrower.collateralETH -= _amount;
            (bool success, ) = payable(msg.sender).call{value: _amount}("");
            require(success, "ERROR");  
        }
        else{
            require(IERC20(token).balanceOf(address(this)) >= _amount,"INSUFFICIENT_AMOUNT");

            uint256 availableWithdrawUSDC = getAccruedSupplyAmount(address(token));
            
            console.log("availableWithdrawUSDC", availableWithdrawUSDC);
            require(availableWithdrawUSDC >= _amount, "CANNOT_WITHDRAW");

            lender.depositUSDC -= _amount;
            totalDepositUSDC -= _amount;
            IERC20(token).transfer(msg.sender, _amount);
        }

        lenderVaults[msg.sender] = lender;
        borrowerVaults[msg.sender] = borrower;  
     
    }
    //getAccruedSupplyAmount 함수는 프로토콜에 예치한 사람이 공급한 유동성을 확인할 수 있는 함수입니다. ( 원금 + 대출이자로 얻은 수익 )
    function getAccruedSupplyAmount(address _tokenAddress) public returns(uint256){
        _depositInterest();
        console.log("lender.depositUSDC", lenderVaults[msg.sender].depositUSDC);
        console.log("lender.rewards", lenderVaults[msg.sender].rewards);
        return lenderVaults[msg.sender].depositUSDC + lenderVaults[msg.sender].rewards;
    }

    function _depositInterest() private {
        LenderVault memory lender = lenderVaults[msg.sender]; 

        //uint256 totalDepositUSDCAccrued = IERC20(token).balanceOf(address(this));
        uint256 depositBlocktime = block.number - totalUSDCUpdate;
        if(totalBorrowUSDC==0) return;
        uint256 totalBorrowUSDCAccrued = _compound(totalBorrowUSDC, INTEREST_RATE, depositBlocktime);
        console.log("totalBorrowUSDC", totalBorrowUSDC);
        console.log("totalBorrowUSDCAccrued", totalBorrowUSDCAccrued);
        //if(totalDepositUSDCAccrued==0) return;
        uint256 interest = totalBorrowUSDCAccrued - totalBorrowUSDC;
        console.log("lender.depositUSDC", lender.depositUSDC);
        console.log("lender.rewards", lender.rewards);
        lender.rewards = interest * lender.depositUSDC / totalDepositUSDC;
        
        totalUSDCUpdate = block.number;
        totalBorrowUSDC = totalBorrowUSDCAccrued;
        lenderVaults[msg.sender] = lender;
    }


    function _borrowInterest(address _tokenAddress) private {
        BorrowerVault memory borrower = borrowerVaults[msg.sender]; 

        uint256 borrowBlocktime = block.number - borrower.borrowBlockNumber;
        console.log("borrower.borrowUSDC", borrower.borrowUSDC);
        borrower.borrowUSDC = _compound(borrower.borrowUSDC, INTEREST_RATE, borrowBlocktime); //1.38819500341472218972641565 10^-7
        borrower.borrowBlockNumber = block.number;
        console.log("borrower.borrowUSDC+interest", borrower.borrowUSDC);
        
        borrowerVaults[msg.sender] = borrower; 
    }    

    

    function _compound (uint principal, uint ratio, uint n) public pure returns (uint) {
        return ABDKMath64x64.mulu (
            _pow (
                ABDKMath64x64.add (
                    ABDKMath64x64.fromUInt (1), ABDKMath64x64.divu (ratio,10**30)),n)
            ,principal);
    }

    function _pow (int128 x, uint n) public pure returns (int128 r) {
        r = ABDKMath64x64.fromUInt (1);
        while (n > 0) {
            if (n % 2 == 1) {
            r = ABDKMath64x64.mul (r, x);
            n -= 1;
            } else {
            x = ABDKMath64x64.mul (x, x);
            n /= 2;
            }
        }
    }

}