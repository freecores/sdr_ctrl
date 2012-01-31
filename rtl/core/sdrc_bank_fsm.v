/*********************************************************************
                                                              
  SDRAM Controller Bank Controller
                                                              
  This file is part of the sdram controller project           
  http://www.opencores.org/cores/sdr_ctrl/                    
                                                              
  Description: 
    This module takes requests from sdrc_req_gen, checks for page hit/miss and
    issues precharge/activate commands and then passes the request to sdrc_xfr_ctl. 
                                                              
  To Do:                                                      
    nothing                                                   
                                                              
  Author(s):                                                  
      - Dinesh Annayya, dinesha@opencores.org                 
  Version  :  1.0  - 8th Jan 2012
                                                              

                                                             
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


`include "sdrc_define.v"

module sdrc_bank_fsm (clk,
		     reset_n,

		     /* Req from req_gen */
		     r2b_req,	   // request
		     r2b_req_id,   // ID
		     r2b_start,	   // First chunk of burst
		     r2b_last,	   // Last chunk of burst
		     r2b_wrap,
		     r2b_raddr,	   // row address
		     r2b_caddr,	   // col address
		     r2b_len,	   // length
		     r2b_write,	   // write request
		     b2r_ack,
                     sdr_dma_last,

		     /* Transfer request to xfr_ctl */
		     b2x_req,	   // Request to xfr_ctl
		     b2x_start,	   // first chunk of transfer
		     b2x_last,	   // last chunk of transfer
		     b2x_wrap,
		     b2x_id,	   // Transfer ID
		     b2x_addr,	   // row/col address
		     b2x_len,	   // transfer length
		     b2x_cmd,	   // transfer command
		     x2b_ack,	   // command accepted
		     
		     /* Status to/from xfr_ctl */
		     tras_ok,      // TRAS OK for this bank
		     xfr_ok,
		     x2b_refresh,  // We did a refresh
		     x2b_pre_ok,   // OK to do a precharge (per bank)
		     x2b_act_ok,   // OK to do an activate
		     x2b_rdok,	   // OK to do a read
		     x2b_wrok,	   // OK to do a write

		     /* current xfr row address of the bank */
		     bank_row,

		     /* SDRAM Timing */
		     tras_delay,   // Active to precharge delay
		     trp_delay,	   // Precharge to active delay
		     trcd_delay);  // Active to R/W delay
   
parameter  APP_AW   = 30;  // Application Address Width
parameter  APP_DW   = 32;  // Application Data Width 
parameter  APP_BW   = 4;   // Application Byte Width
parameter  APP_RW   = 9;   // Application Request Width

parameter  SDR_DW   = 16;  // SDR Data Width 
parameter  SDR_BW   = 2;   // SDR Byte Width
   input                        clk, reset_n;

   /* Req from bank_ctl */
   input 			r2b_req, r2b_start, r2b_last,
				r2b_write, r2b_wrap;
   input [`SDR_REQ_ID_W-1:0] 	r2b_req_id;
   input [11:0] 		r2b_raddr;
   input [11:0] 		r2b_caddr;
   input [APP_RW-1:0] 	r2b_len;
   output 			b2r_ack;
   input                        sdr_dma_last;

   /* Req to xfr_ctl */
   output 			b2x_req, b2x_start, b2x_last,
				tras_ok, b2x_wrap;
   output [`SDR_REQ_ID_W-1:0] 	b2x_id;
   output [11:0] 		b2x_addr;
   output [APP_RW-1:0] 	b2x_len;
   output [1:0] 		b2x_cmd;
   input 			x2b_ack;

   /* Status from xfr_ctl */
   input 			x2b_refresh, x2b_act_ok, x2b_rdok,
				x2b_wrok, x2b_pre_ok, xfr_ok;
   
   input [3:0] 			tras_delay, trp_delay, trcd_delay;

   output [11:0] 			bank_row;

   /****************************************************************************/
   // Internal Nets

   `define BANK_IDLE         3'b000
   `define BANK_PRE          3'b001
   `define BANK_ACT          3'b010
   `define BANK_XFR          3'b011
   `define BANK_DMA_LAST_PRE 3'b100

   reg [2:0] 			bank_st, next_bank_st;
   wire 			b2x_start, b2x_last;
   reg 				l_start, l_last;
   reg 				b2x_req, b2r_ack;
   wire [`SDR_REQ_ID_W-1:0] 	b2x_id;
   reg [`SDR_REQ_ID_W-1:0] 	l_id;
   reg [11:0] 			b2x_addr;
   reg [APP_RW-1:0] 	l_len;
   wire [APP_RW-1:0] 	b2x_len;
   reg [1:0] 			b2x_cmd;
   reg  			bank_valid;
   reg [11:0] 			bank_row;
   reg [3:0] 			tras_cntr, timer0;
   reg 				l_wrap, l_write;
   wire 			b2x_wrap;
   reg [11:0] 			l_raddr;
   reg [11:0] 			l_caddr;
   reg                          l_sdr_dma_last;
   reg                          bank_prech_page_closed;
   
   wire  			tras_ok_internal, tras_ok, activate_bank;
   
   wire 			page_hit, timer0_tc, ld_trp, ld_trcd;

   always @ (posedge clk)
      if (~reset_n) begin
	 bank_valid <= 1'b0;
	 tras_cntr <= 4'b0;
	 timer0 <= 4'b0;
	 bank_st <= `BANK_IDLE;
      end // if (~reset_n)

      else begin

	 bank_valid <= (x2b_refresh || bank_prech_page_closed) ? 1'b0 :  // force the bank status to be invalid
//	 bank_valid <= (x2b_refresh) ? 1'b0 :
		       (activate_bank) ? 1'b1 : bank_valid;

	 tras_cntr <= (activate_bank) ? tras_delay :
		      (~tras_ok_internal) ? tras_cntr - 4'b1 : 4'b0;
	 
	 timer0 <= (ld_trp) ? trp_delay :
		   (ld_trcd) ? trcd_delay :
		   (~timer0_tc) ? timer0 - 4'b1 : timer0;
	 
	 bank_st <= next_bank_st;

      end // else: !if(~reset_n)

   always @ (posedge clk) begin 

      bank_row <= (activate_bank) ? b2x_addr : bank_row;

      if (~reset_n) begin
	 l_start <= 1'b0;
	 l_last <= 1'b0;
	 l_id <= 1'b0;
	 l_len <= 1'b0;
	 l_wrap <= 1'b0;
	 l_write <= 1'b0;
	 l_raddr <= 1'b0;
	 l_caddr <= 1'b0;
         l_sdr_dma_last <= 1'b0;
      end
      else begin
        if (b2r_ack) begin
  	   l_start <= r2b_start;
  	   l_last <= r2b_last;
  	   l_id <= r2b_req_id;
  	   l_len <= r2b_len;
  	   l_wrap <= r2b_wrap;
  	   l_write <= r2b_write;
  	   l_raddr <= r2b_raddr;
  	   l_caddr <= r2b_caddr;
           l_sdr_dma_last <= sdr_dma_last;
        end // if (b2r_ack)
      end

   end // always @ (posedge clk)
   
   assign tras_ok_internal = ~|tras_cntr;
   assign tras_ok = tras_ok_internal;

   assign activate_bank = (b2x_cmd == `OP_ACT) & x2b_ack;

   assign page_hit = (r2b_raddr == bank_row) ? bank_valid : 1'b0;    // its a hit only if bank is valid

   assign timer0_tc = ~|timer0;

   assign ld_trp = (b2x_cmd == `OP_PRE) ? x2b_ack : 1'b0;

   assign ld_trcd = (b2x_cmd == `OP_ACT) ? x2b_ack : 1'b0;
   
   always @ (*) begin

       bank_prech_page_closed = 1'b0;
       b2x_req = 1'b0;
       b2x_cmd = 2'bx;
       b2r_ack = 1'b0;
       b2x_addr = 12'bx;
       next_bank_st = bank_st;

      case (bank_st)

	`BANK_IDLE : begin

	   if (~r2b_req) begin
              bank_prech_page_closed = 1'b0;
	      b2x_req = 1'b0;
	      b2x_cmd = 2'bx;
	      b2r_ack = 1'b0;
	      b2x_addr = 12'bx;
	      next_bank_st = `BANK_IDLE;
	   end // if (~r2b_req)
	   else if (page_hit) begin 
	      b2x_req = (r2b_write) ? x2b_wrok & xfr_ok : 
			x2b_rdok & xfr_ok;
	      b2x_cmd = (r2b_write) ? `OP_WR : `OP_RD;
	      b2r_ack = 1'b1;
	      b2x_addr = r2b_caddr;
	      next_bank_st = (x2b_ack) ? `BANK_IDLE : `BANK_XFR;  // in case of hit, stay here till xfr sm acks
	   end // if (page_hit)
	   else begin  // page_miss
	      b2x_req = tras_ok_internal & x2b_pre_ok;
	      b2x_cmd = `OP_PRE;
	      b2r_ack = 1'b1;
	      b2x_addr = r2b_raddr & 12'hBFF;	   // Dont want to pre all banks!
	      next_bank_st = (l_sdr_dma_last) ? `BANK_PRE : (x2b_ack) ? `BANK_ACT : `BANK_PRE;  // bank was precharged on l_sdr_dma_last
	   end // else: !if(page_hit)

	end // case: `BANK_IDLE

	`BANK_PRE : begin
	   b2x_req = tras_ok_internal & x2b_pre_ok;
	   b2x_cmd = `OP_PRE;
	   b2r_ack = 1'b0;
	   b2x_addr = l_raddr & 12'hBFF;	   // Dont want to pre all banks!
           bank_prech_page_closed = 1'b0;
	   next_bank_st = (x2b_ack) ? `BANK_ACT : `BANK_PRE;
	end // case: `BANK_PRE

	`BANK_ACT : begin
	   b2x_req = timer0_tc & x2b_act_ok;
	   b2x_cmd = `OP_ACT;
	   b2r_ack = 1'b0;
	   b2x_addr = l_raddr;
           bank_prech_page_closed = 1'b0;
	   next_bank_st = (x2b_ack) ? `BANK_XFR : `BANK_ACT;
	end // case: `BANK_ACT
	
	`BANK_XFR : begin
	   b2x_req = (l_write) ? timer0_tc & x2b_wrok & xfr_ok :
		     timer0_tc & x2b_rdok & xfr_ok; 
	   b2x_cmd = (l_write) ? `OP_WR : `OP_RD;
	   b2r_ack = 1'b0;
	   b2x_addr = l_caddr;
           bank_prech_page_closed = 1'b0;
	   next_bank_st = (x2b_refresh) ? `BANK_ACT : 
                          (x2b_ack & l_sdr_dma_last) ? `BANK_DMA_LAST_PRE :
			  (x2b_ack) ? `BANK_IDLE : `BANK_XFR;
	end // case: `BANK_XFR

        `BANK_DMA_LAST_PRE : begin
	   b2x_req = tras_ok_internal & x2b_pre_ok;
	   b2x_cmd = `OP_PRE;
	   b2r_ack = 1'b0;
	   b2x_addr = l_raddr & 12'hBFF;	   // Dont want to pre all banks!
           bank_prech_page_closed = 1'b1;
	   next_bank_st = (x2b_ack) ? `BANK_IDLE : `BANK_DMA_LAST_PRE;
	end // case: `BANK_DMA_LAST_PRE
          
      endcase // case(bank_st)

   end // always @ (bank_st or ...)

   assign b2x_start = (bank_st == `BANK_IDLE) ? r2b_start : l_start;

   assign b2x_last = (bank_st == `BANK_IDLE) ? r2b_last : l_last;

   assign b2x_id = (bank_st == `BANK_IDLE) ? r2b_req_id : l_id;

   assign b2x_len = (bank_st == `BANK_IDLE) ? r2b_len : l_len;

   assign b2x_wrap = (bank_st == `BANK_IDLE) ? r2b_wrap : l_wrap;
   
endmodule // sdr_bank_fsm
