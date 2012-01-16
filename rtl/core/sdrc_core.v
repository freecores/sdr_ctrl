/*********************************************************************
                                                              
  SDRAM Controller Core File                                  
                                                              
  This file is part of the sdram controller project           
  http://www.opencores.org/cores/sdr_ctrl/                    
                                                              
  Description: SDRAM Controller Core Module
    2 types of SDRAMs are supported, 1Mx16 2 bank, or 4Mx16 4 bank.
    This block integrate following sub modules

    sdrc_bs_convert   
        convert the system side 32 bit into equvailent 16/32 SDR format
    sdrc_req_gen    
        This module takes requests from the app, chops them to burst booundaries
        if wrap=0, decodes the bank and passe the request to bank_ctl
   sdrc_xfr_ctl
      This module takes requests from sdr_bank_ctl, runs the transfer and
      controls data flow to/from the app. At the end of the transfer it issues a
      burst terminate if not at the end of a burst and another command to this
      bank is not available.

   sdrc_bank_ctl
      This module takes requests from sdr_req_gen, checks for page hit/miss and
      issues precharge/activate commands and then passes the request to
      sdr_xfr_ctl. 


  Assumption: SDRAM Pads should be placed near to this module. else
  user should add a FF near the pads
                                                              
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
module sdrc_core 
           (
		clk,
                pad_clk,
		reset_n,
                sdr_width,

		/* Request from app */
		app_req,	        // Transfer Request
		app_req_addr,	        // SDRAM Address
		app_req_addr_mask,	// Address mask for queue wrap
		app_req_len,	        // Burst Length (in 16 bit words)
		app_req_wrap,	        // Wrap mode request (xfr_len = 4)
		app_req_wr_n,	        // 0 => Write request, 1 => read req
		app_req_ack,	        // Request has been accepted
		sdr_core_busy_n,	        // OK to arbitrate next request
		cfg_req_depth,	        //how many req. buffer should hold
		
		app_wr_data,
                app_wr_en_n,
		app_rd_data,
		app_rd_valid,
		app_wr_next_req,
		sdr_init_done,
		app_req_dma_last,

		/* Interface to SDRAMs */
		sdr_cs_n,
		sdr_cke,
		sdr_ras_n,
		sdr_cas_n,
		sdr_we_n,
		sdr_dqm,
		sdr_ba,
		sdr_addr, 
		pad_sdr_din,
		sdr_dout,
		sdr_den_n,

		/* Parameters */
		cfg_sdr_en,
		cfg_sdr_dev_config,	// using 64M/4bank SDRAMs
		cfg_sdr_mode_reg,
		cfg_sdr_tras_d,
		cfg_sdr_trp_d,
		cfg_sdr_trcd_d,
		cfg_sdr_cas,
		cfg_sdr_trcar_d,
		cfg_sdr_twr_d,
		cfg_sdr_rfsh,
		cfg_sdr_rfmax);
  
parameter  APP_AW   = 30;  // Application Address Width
parameter  APP_DW   = 32;  // Application Data Width 
parameter  APP_BW   = 4;   // Application Byte Width
parameter  APP_RW   = 9;   // Application Request Width

parameter  SDR_DW   = 16;  // SDR Data Width 
parameter  SDR_BW   = 2;   // SDR Byte Width
             

//-----------------------------------------------
// Global Variable
// ----------------------------------------------
input                   clk                 ; // SDRAM Clock 
input                   pad_clk             ; // SDRAM Clock from Pad, used for registering Read Data
input                   reset_n             ; // Reset Signal
input                   sdr_width           ; // 0 - 32 Bit SDR, 1 - 16 Bit SDR

//------------------------------------------------
// Request from app
//------------------------------------------------
input 			app_req             ; // Application Request
input [APP_AW-1:0] 	app_req_addr        ; // Address 
input [APP_AW-2:0]      app_req_addr_mask   ; // Address Mask
input 			app_req_wr_n        ; // 0 - Write, 1 - Read
input                   app_req_wrap        ; // Address Wrap
output                  app_req_ack         ; // Application Request Ack
output 			sdr_core_busy_n     ; // 0 - busy, 1 - free
		
input [APP_DW-1:0] 	app_wr_data         ; // Write Data
output 		        app_wr_next_req     ; // Next Write Data Request
input [APP_BW-1:0] 	app_wr_en_n         ; // Byte wise Write Enable
output [APP_DW-1:0] 	app_rd_data         ; // Read Data
output                  app_rd_valid        ; // Read Valid
		
//------------------------------------------------
// Interface to SDRAMs
//------------------------------------------------
output                  sdr_cke             ; // SDRAM CKE
output 			sdr_cs_n            ; // SDRAM Chip Select
output                  sdr_ras_n           ; // SDRAM ras
output                  sdr_cas_n           ; // SDRAM cas
output			sdr_we_n            ; // SDRAM write enable
output [SDR_BW-1:0] 	sdr_dqm             ; // SDRAM Data Mask
output [1:0] 		sdr_ba              ; // SDRAM Bank Enable
output [11:0] 		sdr_addr            ; // SDRAM Address
input [SDR_DW-1:0] 	pad_sdr_din         ; // SDRA Data Input
output [SDR_DW-1:0] 	sdr_dout            ; // SDRAM Data Output
output [SDR_BW-1:0] 	sdr_den_n           ; // SDRAM Data Output enable

//------------------------------------------------
// Configuration Parameter
//------------------------------------------------
output                  sdr_init_done       ;
input [3:0] 		cfg_sdr_tras_d      ;
input [3:0]             cfg_sdr_trp_d       ;
input [3:0]             cfg_sdr_trcd_d      ;
input 			cfg_sdr_en          ; 
input [1:0]             cfg_sdr_dev_config  ; // 2'b00 - 8 MB, 01 - 16 MB, 10 - 32 MB , 11 - 64 MB
input [1:0] 		cfg_req_depth       ;
input [APP_RW-1:0]	app_req_len         ;
input [11:0] 		cfg_sdr_mode_reg    ;
input [2:0] 		cfg_sdr_cas         ;
input [3:0] 		cfg_sdr_trcar_d     ;
input [3:0]             cfg_sdr_twr_d       ;
input [`SDR_RFSH_TIMER_W-1 : 0] cfg_sdr_rfsh;
input [`SDR_RFSH_ROW_CNT_W -1 : 0] cfg_sdr_rfmax;
input                   app_req_dma_last;    // this signal should close the bank

/****************************************************************************/
// Internal Nets
   
// SDR_REQ_GEN
wire 			r2x_idle, app_req_ack,app_req_ack_int;
wire                    app_req_dma_last_int;
wire 			r2b_req, r2b_start, r2b_last, r2b_write;
wire [`SDR_REQ_ID_W-1:0]r2b_req_id;
wire [1:0] 		r2b_ba;
wire [11:0] 		r2b_raddr;
wire [11:0] 		r2b_caddr;
wire [APP_RW-1:0] 	r2b_len;

// SDR BANK CTL
wire 			b2r_ack, b2x_idle;
wire 			b2x_req, b2x_start, b2x_last, b2x_tras_ok;
wire [`SDR_REQ_ID_W-1:0]b2x_id;
wire [1:0] 		b2x_ba;
wire  			b2x_ba_last;
wire [11:0] 		b2x_addr;
wire [APP_RW-1:0] 	b2x_len;
wire [1:0] 		b2x_cmd;

// SDR_XFR_CTL
wire 			x2b_ack;
wire [3:0] 		x2b_pre_ok;
wire 			x2b_refresh, x2b_act_ok, x2b_rdok, x2b_wrok;
wire 			xfr_rdstart, xfr_rdlast;
wire 			xfr_wrstart, xfr_wrlast;
wire [`SDR_REQ_ID_W-1:0]xfr_id;
wire [13:0]		xfr_addr_msb;
wire [APP_DW-1:0] 	app_rd_data;
wire 			app_wr_next_req, app_rd_valid;
wire 			sdr_cs_n, sdr_cke, sdr_ras_n, sdr_cas_n, sdr_we_n; 
wire [SDR_BW-1:0] 	sdr_dqm;
wire [1:0] 		sdr_ba;
wire [11:0] 		sdr_addr;
wire [SDR_DW-1:0] 	sdr_dout;
wire [SDR_DW-1:0] 	sdr_dout_int;
wire [SDR_BW-1:0] 	sdr_den_n;
wire [SDR_BW-1:0] 	sdr_den_n_int;

wire [1:0] 		xfr_bank_sel;
wire [1:0] 		cfg_sdr_dev_config;

wire [APP_AW:0]          app_req_addr_int;
wire [APP_AW-1:0]        app_req_addr;
wire [APP_RW-1:0]        app_req_len_int;
wire [APP_RW-1:0]        app_req_len;

wire [APP_DW-1:0]        app_wr_data;
wire [SDR_DW-1:0]        add_wr_data_int;
wire [APP_BW-1:0]        app_wr_en_n;
wire [SDR_BW-1:0]        app_wr_en_n_int;

//wire [31:0] app_rd_data;
wire [SDR_DW-1:0]        app_rd_data_int;

//
wire                     app_req_int;
wire                     r2b_wrap;
wire                     b2r_arb_ok;
wire                     b2x_wrap;
wire                     app_wr_next_int;
wire                     app_rd_valid_int;

// synopsys translate_off 
   wire [3:0]           sdr_cmd;
   assign sdr_cmd = {sdr_cs_n, sdr_ras_n, sdr_cas_n, sdr_we_n}; 
// synopsys translate_on 

   assign sdr_den_n = sdr_width ? {2'b00,sdr_den_n_int[1:0]} : sdr_den_n_int;
   assign sdr_dout = sdr_width ? {16'h0000,sdr_dout_int[15:0]} : sdr_dout_int;


   /****************************************************************************/
   // Instantiate sdr_req_gen
   // This module takes requests from the app, chops them to burst booundaries
   // if wrap=0, decodes the bank and passe the request to bank_ctl

   sdrc_req_gen u_req_gen (
          .clk                (clk          ),
          .reset_n            (reset_n            ),
          .sdr_dev_config     (cfg_sdr_dev_config ),

	/* Request from app */
          .r2x_idle           (r2x_idle           ),
          .req                (app_req_int        ),
          .req_id             (4'b0               ),
          .req_addr           (app_req_addr_int   ),
          .req_addr_mask      (app_req_addr_mask  ),
          .req_len            (app_req_len_int    ),
          .req_wrap           (app_req_wrap       ),
          .req_wr_n           (app_req_wr_n       ),
          .req_ack            (app_req_ack_int      ),
          .sdr_core_busy_n    (sdr_core_busy_n    ),
		
       /* Req to bank_ctl */
          .r2b_req            (r2b_req            ),
          .r2b_req_id         (r2b_req_id         ),
          .r2b_start          (r2b_start          ),
          .r2b_last           (r2b_last           ),
          .r2b_wrap           (r2b_wrap           ),
          .r2b_ba             (r2b_ba             ),
          .r2b_raddr          (r2b_raddr          ),
          .r2b_caddr          (r2b_caddr          ),
          .r2b_len            (r2b_len            ),
          .r2b_write          (r2b_write          ),
          .b2r_ack            (b2r_ack            ),
          .b2r_arb_ok         (b2r_arb_ok         ),
          .sdr_width          (sdr_width          ),
          .sdr_init_done      (sdr_init_done      )
     );

   /****************************************************************************/
   // Instantiate sdr_bank_ctl
   // This module takes requests from sdr_req_gen, checks for page hit/miss and
   // issues precharge/activate commands and then passes the request to
   // sdr_xfr_ctl. 

   sdrc_bank_ctl u_bank_ctl (
          .clk                (clk          ),
          .reset_n            (reset_n            ),
          .a2b_req_depth      (cfg_req_depth      ),
			      
      /* Req from req_gen */
          .r2b_req            (r2b_req            ),
          .r2b_req_id         (r2b_req_id         ),
          .r2b_start          (r2b_start          ),
          .r2b_last           (r2b_last           ),
          .r2b_wrap           (r2b_wrap           ),
          .r2b_ba             (r2b_ba             ),
          .r2b_raddr          (r2b_raddr          ),
          .r2b_caddr          (r2b_caddr          ),
          .r2b_len            (r2b_len            ),
          .r2b_write          (r2b_write          ),
          .b2r_arb_ok         (b2r_arb_ok         ),
          .b2r_ack            (b2r_ack            ),
			      
      /* Transfer request to xfr_ctl */
          .b2x_idle           (b2x_idle           ),
          .b2x_req            (b2x_req            ),
          .b2x_start          (b2x_start          ),
          .b2x_last           (b2x_last           ),
          .b2x_wrap           (b2x_wrap           ),
          .b2x_id             (b2x_id             ),
          .b2x_ba             (b2x_ba             ),
          .b2x_addr           (b2x_addr           ),
          .b2x_len            (b2x_len            ),
          .b2x_cmd            (b2x_cmd            ),
          .x2b_ack            (x2b_ack            ),
		     
      /* Status from xfr_ctl */
          .b2x_tras_ok        (b2x_tras_ok        ),
          .x2b_refresh        (x2b_refresh        ),
          .x2b_pre_ok         (x2b_pre_ok         ),
          .x2b_act_ok         (x2b_act_ok         ),
          .x2b_rdok           (x2b_rdok           ),
          .x2b_wrok           (x2b_wrok           ),

      /* for generate cuurent xfr address msb */
          .sdr_dev_config     (cfg_sdr_dev_config ),
          .sdr_req_norm_dma_last(app_req_dma_last_int),
          .xfr_bank_sel       (xfr_bank_sel       ),
          .xfr_addr_msb       (xfr_addr_msb       ),

       /* SDRAM Timing */
          .tras_delay         (cfg_sdr_tras_d     ),
          .trp_delay          (cfg_sdr_trp_d      ),
          .trcd_delay         (cfg_sdr_trcd_d     )
      );
   
   /****************************************************************************/
   // Instantiate sdr_xfr_ctl
   // This module takes requests from sdr_bank_ctl, runs the transfer and
   // controls data flow to/from the app. At the end of the transfer it issues a
   // burst terminate if not at the end of a burst and another command to this
   // bank is not available.

   sdrc_xfr_ctl u_xfr_ctl (
          .clk                (clk          ),
          .reset_n            (reset_n            ),
			    
      /* Transfer request from bank_ctl */
          .r2x_idle           (r2x_idle           ),
          .b2x_idle           (b2x_idle           ),
          .b2x_req            (b2x_req            ),
          .b2x_start          (b2x_start          ),
          .b2x_last           (b2x_last           ),
          .b2x_wrap           (b2x_wrap           ),
          .b2x_id             (b2x_id             ),
          .b2x_ba             (b2x_ba             ),
          .b2x_addr           (b2x_addr           ),
          .b2x_len            (b2x_len            ),
          .b2x_cmd            (b2x_cmd            ),
          .x2b_ack            (x2b_ack            ),
		     
       /* Status to bank_ctl, req_gen */
          .b2x_tras_ok        (b2x_tras_ok        ),
          .x2b_refresh        (x2b_refresh        ),
          .x2b_pre_ok         (x2b_pre_ok         ),
          .x2b_act_ok         (x2b_act_ok         ),
          .x2b_rdok           (x2b_rdok           ),
          .x2b_wrok           (x2b_wrok           ),
		    
       /* SDRAM I/O */
          .sdr_cs_n           (sdr_cs_n           ),
          .sdr_cke            (sdr_cke            ),
          .sdr_ras_n          (sdr_ras_n          ),
          .sdr_cas_n          (sdr_cas_n          ),
          .sdr_we_n           (sdr_we_n           ),
          .sdr_dqm            (sdr_dqm            ),
          .sdr_ba             (sdr_ba             ),
          .sdr_addr           (sdr_addr           ),
          .sdr_din            (pad_sdr_din        ),
          .sdr_dout           (sdr_dout_int       ),
          .sdr_den_n          (sdr_den_n_int      ),
		    
      /* Data Flow to the app */
          .x2a_rdstart        (xfr_rdstart        ),
          .x2a_wrstart        (xfr_wrstart        ),
          .x2a_id             (xfr_id             ),
          .x2a_rdlast         (xfr_rdlast         ),
          .x2a_wrlast         (xfr_wrlast         ),
          .app_wrdt           (add_wr_data_int    ),
          .app_wren_n         (app_wr_en_n_int    ),
          .x2a_wrnext         (app_wr_next_int    ),
          .x2a_rddt           (app_rd_data_int    ),
          .x2a_rdok           (app_rd_valid_int   ),
          .sdr_init_done      (sdr_init_done      ),
			    
      /* SDRAM Parameters */
          .sdram_enable       (cfg_sdr_en         ),
          .sdram_mode_reg     (cfg_sdr_mode_reg   ),
		    
      /* current xfr bank */
          .xfr_bank_sel       (xfr_bank_sel       ),

      /* SDRAM Timing */
          .cas_latency        (cfg_sdr_cas        ),
          .trp_delay          (cfg_sdr_trp_d      ),
          .trcar_delay        (cfg_sdr_trcar_d    ),
          .twr_delay          (cfg_sdr_twr_d      ),
          .rfsh_time          (cfg_sdr_rfsh       ),
          .rfsh_rmax          (cfg_sdr_rfmax      )
    );
   
sdrc_bs_convert u_bs_convert (
          .clk                (clk          ),
          .reset_n            (reset_n            ),
          .sdr_width          (sdr_width          ),

          .app_req_addr       (app_req_addr       ),  
          .app_req_addr_int   (app_req_addr_int   ),  
          .app_req_len        (app_req_len        ),  
          .app_req_len_int    (app_req_len_int    ),  
          .app_sdr_req        (app_req            ),  
          .app_sdr_req_int    (app_req_int        ),  
          .app_req_dma_last   (app_req_dma_last   ), 
          .app_req_dma_last_int(app_req_dma_last_int),
          .app_req_wr_n       (app_req_wr_n       ),
          .app_req_ack_int    (app_req_ack_int    ),
          .app_req_ack        (app_req_ack        ),

          .app_wr_data        (app_wr_data        ),
          .app_wr_data_int    (add_wr_data_int    ),
          .app_wr_en_n        (app_wr_en_n        ),
          .app_wr_en_n_int    (app_wr_en_n_int    ),
          .app_wr_next_int    (app_wr_next_int    ),
          .app_wr_next        (app_wr_next_req    ),

          .app_rd_data_int    (app_rd_data_int    ),
          .app_rd_data        (app_rd_data        ),
          .app_rd_valid_int   (app_rd_valid_int   ),
          .app_rd_valid       (app_rd_valid       )
       );   
   
endmodule // sdrc_core
