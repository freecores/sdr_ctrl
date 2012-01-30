/*********************************************************************
                                                              
  SDRAM Controller Request Generation                                  
                                                              
  This file is part of the sdram controller project           
  http://www.opencores.org/cores/sdr_ctrl/                    
                                                              
  Description: SDRAM Controller Reguest Generation

  Address Generation Based on cfg_colbits
     cfg_colbits= 2'b00
            Address[7:0]    - Column Address
            Address[9:8]    - Bank Address
            Address[21:10]  - Row Address
     cfg_colbits= 2'b01
            Address[8:0]    - Column Address
            Address[10:9]   - Bank Address
            Address[22:11]  - Row Address
     cfg_colbits= 2'b10
            Address[9:0]    - Column Address
            Address[11:10]   - Bank Address
            Address[23:12]  - Row Address
     cfg_colbits= 2'b11
            Address[10:0]    - Column Address
            Address[12:11]   - Bank Address
            Address[24:13]  - Row Address

  The SDRAMs are operated in 4 beat burst mode.
  This module takes requests from the memory controller, 
  chops them to page boundaries if wrap=0, 
  and passes the request to bank_ctl
                                                              
  To Do:                                                      
    nothing                                                   
                                                              
  Author(s):                                                  
      - Dinesh Annayya, dinesha@opencores.org                 
  Version  : 1.0 - 8th Jan 2012
                                                              

                                                             
 Copyright (C) 2000 Authors and OPENCORES.ORG                
                                                             
 This source file may be used and distributed without         
 restriction provided that this copyright statement is not    
 removed from the file and that any derivative work contains  
 the original copyright notice and the associated disclaimer. 
                                                              
 This source file is free software; you can redistribute it   
 and/or modify it under the terms of the GNU Lesser General   
 Public License as published by the Free Software Foundation; 
 either version 2.1 of the License, or (at your option) any   
later version.                                               
                                                              
 This source is distributed in the hope that it will be       
 useful, but WITHOUT ANY WARRANTY; without even the implied   
 warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      
 PURPOSE.  See the GNU Lesser General Public License for more 
 details.                                                     
                                                              
 You should have received a copy of the GNU Lesser General    
 Public License along with this source; if not, download it   
 from http://www.opencores.org/lgpl.shtml                     
                                                              
*******************************************************************/

`include "sdrc.def"

module sdrc_req_gen (clk,
		    reset_n,

		    /* Request from app */
		    req,	// Transfer Request
		    req_id,	// ID for this transfer
		    req_addr,	// SDRAM Address
		    req_addr_mask,
		    req_len,	// Burst Length (in 32 bit words)
		    req_wrap,	// Wrap mode request (xfr_len = 4)
		    req_wr_n,	// 0 => Write request, 1 => read req
		    req_ack,	// Request has been accepted
		    sdr_core_busy_n,	// SDRAM Core Busy Indication
		    cfg_colbits,
		    
		    /* Req to bank_ctl */
		    r2x_idle,
		    r2b_req,	// request
		    r2b_req_id,	// ID
		    r2b_start,	// First chunk of burst
		    r2b_last,	// Last chunk of burst
		    r2b_wrap,	// Wrap Mode
		    r2b_ba,	// bank address
		    r2b_raddr,	// row address
		    r2b_caddr,	// col address
		    r2b_len,	// length
		    r2b_write,	// write request
		    b2r_ack,
		    b2r_arb_ok,
		    sdr_width,
		    sdr_init_done);

parameter  APP_AW   = 30;  // Application Address Width
parameter  APP_DW   = 32;  // Application Data Width 
parameter  APP_BW   = 4;   // Application Byte Width
parameter  APP_RW   = 9;   // Application Request Width

parameter  SDR_DW   = 16;  // SDR Data Width 
parameter  SDR_BW   = 2;   // SDR Byte Width

   input                        clk, reset_n;
   input [1:0]                  cfg_colbits; // 2'b00 - 8 Bit column address, 2'b01 - 9 Bit, 10 - 10 bit, 11 - 11Bits

   /* Request from app */
   input 			req;
   input [`SDR_REQ_ID_W-1:0] 	req_id;
   input [APP_AW:0] 	req_addr;
   input [APP_AW-2:0] 	req_addr_mask;
   input [APP_RW-1:0] 	req_len;
   input 			req_wr_n, req_wrap;
   output 			req_ack, sdr_core_busy_n;
		
   /* Req to bank_ctl */
   output 			r2x_idle, r2b_req, r2b_start, r2b_last,
				r2b_write, r2b_wrap; 
   output [`SDR_REQ_ID_W-1:0] 	r2b_req_id;
   output [1:0] 		r2b_ba;
   output [11:0] 		r2b_raddr;
   output [11:0] 		r2b_caddr;
   output [APP_RW-1:0] 	r2b_len;
   input 			b2r_ack, b2r_arb_ok, sdr_init_done;
//
   input [1:0] 			sdr_width; // 2'b00 - 32 Bit, 2'b01 - 16 Bit, 2'b1x - 8Bit
                                         

   /****************************************************************************/
   // Internal Nets

   `define REQ_IDLE        1'b0
   `define REQ_ACTIVE      1'b1

   reg  			req_st, next_req_st;
   reg 				r2x_idle, req_ack, r2b_req, r2b_start, 
				r2b_write, req_idle, req_ld, lcl_wrap;
   reg [`SDR_REQ_ID_W-1:0] 	r2b_req_id;
   reg [APP_RW-1:0] 	lcl_req_len;

   wire 			r2b_last, page_ovflw;
   wire [APP_RW-1:0] 	r2b_len, next_req_len;
   wire [APP_RW:0] 	max_r2b_len;

   wire [1:0] 			r2b_ba;
   wire [11:0] 			r2b_raddr;
   wire [11:0] 			r2b_caddr;

   reg [APP_AW-1:0] 	curr_sdr_addr, sdr_addrs_mask;
   wire [APP_AW-1:0] 	next_sdr_addr, next_sdr_addr1;

   //
   // The maximum length for no page overflow is 200h/100h - caddr. Split a request
   // into 2 or more requests if it crosses a page boundary.
   // For non-queue accesses req_addr_mask is set to all 1 and the accesses
   // proceed linearly. 
   // All queues end on a 512 byte boundary (actually a 1K boundary). For Q
   // accesses req_addr_mask is set to LSB of 1 and MSB of 0 to constrain the
   // accesses within the space for a Q. When splitting and calculating the next
   // address only the LSBs are incremented, the MSBs remain = req_addr.
   //
   assign max_r2b_len = (cfg_colbits == 2'b00) ? (12'h100 - r2b_caddr) :
	                (cfg_colbits == 2'b01) ? (12'h200 - r2b_caddr) :
			(cfg_colbits == 2'b10) ? (12'h400 - r2b_caddr) : (12'h800 - r2b_caddr);

   assign page_ovflw = ({1'b0, lcl_req_len} > max_r2b_len) ? ~lcl_wrap : 1'b0;

   assign r2b_len = (page_ovflw) ? max_r2b_len : lcl_req_len;

   assign next_req_len = lcl_req_len - r2b_len;

   assign next_sdr_addr1 = curr_sdr_addr + r2b_len;

   // Wrap back based on the mask
   assign next_sdr_addr = (sdr_addrs_mask & next_sdr_addr1) | 
			  (~sdr_addrs_mask & curr_sdr_addr);

   assign sdr_core_busy_n = req_idle & b2r_arb_ok & sdr_init_done;

   assign r2b_wrap = lcl_wrap;

   assign r2b_last = ~page_ovflw;
//
//
//
   always @ (posedge clk) begin

      r2b_start <= (req_ack) ? 1'b1 :
		   (b2r_ack) ? 1'b0 : r2b_start;

      r2b_write <= (req_ack) ? ~req_wr_n : r2b_write;

      r2b_req_id <= (req_ack) ? req_id : r2b_req_id;

      lcl_wrap <= (req_ack) ? req_wrap : lcl_wrap;
	     
      lcl_req_len <= (req_ack) ? req_len  :
		   (req_ld) ? next_req_len : lcl_req_len;

      curr_sdr_addr <= (req_ack) ? req_addr :
		       (req_ld) ? next_sdr_addr : curr_sdr_addr;

      sdr_addrs_mask <= (req_ack) ?((sdr_width == 2'b00)  ? req_addr_mask :
	                            (sdr_width == 2'b01)  ? {req_addr_mask,req_addr_mask[0]} : 
				                            {req_addr_mask,req_addr_mask[1:0]}) : sdr_addrs_mask;
      
   end // always @ (posedge clk)
   
   always @ (*) begin

      case (req_st)      // synopsys full_case parallel_case

	`REQ_IDLE : begin
	   r2x_idle = ~req;
	   req_idle = 1'b1;
	   req_ack = req & b2r_arb_ok;
	   req_ld = 1'b0;
	   r2b_req = 1'b0;
	   next_req_st = (req & b2r_arb_ok) ? `REQ_ACTIVE : `REQ_IDLE;
	end // case: `REQ_IDLE

	`REQ_ACTIVE : begin
	   r2x_idle = 1'b0;
	   req_idle = 1'b0;
	   req_ack = 1'b0;
	   req_ld = b2r_ack;
	   r2b_req = 1'b1;                       // req_gen to bank_req
	   next_req_st = (b2r_ack & r2b_last) ? `REQ_IDLE : `REQ_ACTIVE;
	end // case: `REQ_ACTIVE

      endcase // case(req_st)

   end // always @ (req_st or ....)

   always @ (posedge clk)
      if (~reset_n) begin
	 req_st <= `REQ_IDLE;
      end // if (~reset_n)
      else begin
	 req_st <= next_req_st;
      end // else: !if(~reset_n)
//
// addrs bits for the bank, row and column
//

// Bank Bits are always - 2 Bits
   assign r2b_ba = (cfg_colbits == 2'b00) ? {curr_sdr_addr[9:8]}   :
	           (cfg_colbits == 2'b01) ? {curr_sdr_addr[10:9]}  :
	           (cfg_colbits == 2'b10) ? {curr_sdr_addr[11:10]} : curr_sdr_addr[12:11];

   /********************
   *  Colbits Mapping:
   *           2'b00 - 8 Bit
   *           2'b01 - 16 Bit
   *           2'b10 - 10 Bit
   *           2'b11 - 11 Bits
   ************************/
   assign r2b_caddr = (cfg_colbits == 2'b00) ? {4'b0, curr_sdr_addr[7:0]} :
	              (cfg_colbits == 2'b01) ? {3'b0, curr_sdr_addr[8:0]} :
	              (cfg_colbits == 2'b10) ? {2'b0, curr_sdr_addr[9:0]} : {1'b0, curr_sdr_addr[10:0]};

   assign r2b_raddr = (cfg_colbits == 2'b00)  ? curr_sdr_addr[21:10] :
	              (cfg_colbits == 2'b01)  ? curr_sdr_addr[22:11] :
	              (cfg_colbits == 2'b10)  ? curr_sdr_addr[23:12] : curr_sdr_addr[24:13];
	   
   
endmodule // sdr_req_gen
