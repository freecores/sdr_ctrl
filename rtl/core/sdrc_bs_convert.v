/*********************************************************************
                                                              
  SDRAM Controller buswidth converter                                  
                                                              
  This file is part of the sdram controller project           
  http://www.opencores.org/cores/sdr_ctrl/                    
                                                              
  Description: SDRAM Controller Buswidth converter

  This module does write/read data transalation between
     application data to SDRAM bus width
                                                              
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

`include "sdrc.def"
module sdrc_bs_convert (
                    clk,
                    reset_n,
                    sdr_width,

                    app_req_addr,
                    app_req_addr_int,
                    app_req_len,
                    app_req_len_int,
                    app_sdr_req,
                    app_sdr_req_int,
                    app_req_dma_last,
                    app_req_dma_last_int,
                    app_req_wr_n,
                    app_req_ack,
                    app_req_ack_int,

                    app_wr_data,
                    app_wr_data_int,
                    app_wr_en_n,
                    app_wr_en_n_int,
                    app_wr_next_int,
                    app_wr_next,

                    app_rd_data_int,
                    app_rd_data,
                    app_rd_valid_int,
                    app_rd_valid
		);
parameter  APP_AW   = 30;  // Application Address Width
parameter  APP_DW   = 32;  // Application Data Width 
parameter  APP_BW   = 4;   // Application Byte Width
parameter  APP_RW   = 9;   // Application Request Width

parameter  SDR_DW   = 16;  // SDR Data Width 
parameter  SDR_BW   = 2;   // SDR Byte Width
   
input                    clk;
input                    reset_n ;
input [1:0]             sdr_width           ; // 2'b00 - 32 Bit SDR, 2'b01 - 16 Bit SDR, 2'b1x - 8 Bit

input [APP_AW-1:0]       app_req_addr;
output [APP_AW:0]        app_req_addr_int;
input  [APP_RW-1:0]      app_req_len ;
output [APP_RW-1:0]      app_req_len_int; 
input                    app_req_wr_n;
input                    app_sdr_req;
output                   app_sdr_req_int;
input                    app_req_dma_last;
output                   app_req_dma_last_int;
input                    app_req_ack_int;
output                   app_req_ack;

input  [APP_DW-1:0]      app_wr_data;
output [SDR_DW-1:0]      app_wr_data_int;
input  [APP_BW-1:0]      app_wr_en_n;
output [SDR_BW-1:0]      app_wr_en_n_int;
input                    app_wr_next_int;
output                   app_wr_next;

input [SDR_DW-1:0]       app_rd_data_int;
output [APP_DW-1:0]      app_rd_data;
input                    app_rd_valid_int;
output                   app_rd_valid;

reg [APP_AW:0]           app_req_addr_int;
reg [APP_RW-1:0]         app_req_len_int;

reg                      app_req_dma_last_int;
reg                      app_sdr_req_int;
reg                      app_req_ack;

reg [APP_DW-1:0]         app_rd_data;
reg                      app_rd_valid;
reg [SDR_DW-1:0]         app_wr_data_int;
reg [SDR_BW-1:0]         app_wr_en_n_int;
reg                      app_wr_next;

reg [23:0]               saved_rd_data;
reg [7:0]                rd_xfr_count;
reg [7:0]                wr_xfr_count;


wire                  ok_to_req;                   

assign ok_to_req = ((wr_xfr_count == 0) && (rd_xfr_count == 0));

always @(*) begin
        if(sdr_width == 2'b00) // 32 Bit SDR Mode
          begin
            app_req_addr_int = {1'b0,app_req_addr};
            app_req_len_int = app_req_len;
            app_wr_data_int = app_wr_data;
            app_wr_en_n_int = app_wr_en_n;
            app_req_dma_last_int = app_req_dma_last;
            app_sdr_req_int = app_sdr_req;
            app_wr_next = app_wr_next_int;
            app_rd_data = app_rd_data_int;
            app_rd_valid = app_rd_valid_int;
            app_req_ack = app_req_ack_int;
          end
        else if(sdr_width == 2'b01) // 16 Bit SDR Mode
        begin
           // Changed the address and length to match the 16 bit SDR Mode
            app_req_addr_int = {app_req_addr,1'b0};
            app_req_len_int = {app_req_len,1'b0};
            app_req_dma_last_int = app_req_dma_last;
            app_sdr_req_int = app_sdr_req && ok_to_req;
            app_req_ack = app_req_ack_int;
            app_wr_next = (app_wr_next_int & wr_xfr_count[0]);
            app_rd_valid = (rd_xfr_count & rd_xfr_count[0]);
            if(wr_xfr_count[0] == 1'b1)
              begin
                app_wr_en_n_int = app_wr_en_n[3:2];
                app_wr_data_int = app_wr_data[31:16];
              end
            else
              begin
                app_wr_en_n_int = app_wr_en_n[1:0];
                app_wr_data_int = app_wr_data[15:0];
              end
            
            app_rd_data = {app_rd_data_int,saved_rd_data[15:0]};
        end else  // 8 Bit SDR Mode
        begin
           // Changed the address and length to match the 16 bit SDR Mode
            app_req_addr_int = {app_req_addr,2'b0};
            app_req_len_int = {app_req_len,2'b0};
            app_req_dma_last_int = app_req_dma_last;
            app_sdr_req_int = app_sdr_req && ok_to_req;
            app_req_ack = app_req_ack_int;
            app_wr_next = (app_wr_next_int & (wr_xfr_count[1:0]== 2'b01));
            app_rd_valid = (rd_xfr_count &   (rd_xfr_count[1:0]== 2'b01));
	    // Note: counter is down counter from 00 -> 11 -> 10 -> 01 --> 00
            if(wr_xfr_count[1:0] == 2'b01)
            begin
                app_wr_en_n_int = app_wr_en_n[3];
                app_wr_data_int = app_wr_data[31:24];
            end
            else if(wr_xfr_count[1:0] == 2'b10)
            begin
                app_wr_en_n_int = app_wr_en_n[2];
                app_wr_data_int = app_wr_data[23:16];
            end
            else if(wr_xfr_count[1:0] == 2'b11)
            begin
                app_wr_en_n_int = app_wr_en_n[1];
                app_wr_data_int = app_wr_data[15:8];
            end
            else begin
                app_wr_en_n_int = app_wr_en_n[0];
                app_wr_data_int = app_wr_data[7:0];
            end
            
            app_rd_data = {app_rd_data_int,saved_rd_data[23:0]};
          end
     end


reg lcl_mc_req_wr_n;

always @(posedge clk)
  begin
    if(!reset_n)
      begin
        rd_xfr_count    <= 8'b0;
        wr_xfr_count    <= 8'b0;
        lcl_mc_req_wr_n <= 1'b1;
	saved_rd_data   <= 24'h0;
      end
    else begin
        lcl_mc_req_wr_n <= app_req_wr_n;

	// During Write Phase
        if(app_req_ack && (app_req_wr_n == 0)) begin
           wr_xfr_count    <= app_req_len_int;
        end
        else if(app_wr_next_int & !lcl_mc_req_wr_n) begin
           wr_xfr_count <= wr_xfr_count - 1'b1;
        end

	// During Read Phase
        if(app_req_ack && app_req_wr_n) begin
           rd_xfr_count    <= app_req_len_int;
        end
        else if(app_rd_valid_int & lcl_mc_req_wr_n) begin
           rd_xfr_count   <= rd_xfr_count - 1'b1;
	   if(sdr_width == 2'b01) // 16 Bit SDR Mode
	      saved_rd_data[15:0]  <= app_rd_data_int;
            else begin// 8 bit SDR Mode - 
		      // Note: counter is down counter from 00 -> 11 -> 10 -> 01 --> 00
	       if(rd_xfr_count[1:0] == 2'b00)      saved_rd_data[7:0]   <= app_rd_data_int[7:0];
	       else if(rd_xfr_count[1:0] == 2'b11) saved_rd_data[15:8]  <= app_rd_data_int[7:0];
	       else if(rd_xfr_count[1:0] == 2'b10) saved_rd_data[23:16] <= app_rd_data_int[7:0];
	    end
        end
    end
end

endmodule // sdr_bs_convert
