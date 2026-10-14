// Copyright 2020 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Authors:
// - Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
// - Andreas Kurth <akurth@iis.ee.ethz.ch>

`include "axi/assign.svh"

module tb_axi_dw_upsizer #(
    // AXI Parameters
    parameter int unsigned TbAxiAddrWidth        = 64  ,
    parameter int unsigned TbAxiIdWidth          = 4   ,
    parameter int unsigned TbAxiSlvPortDataWidth = 32  ,
    parameter int unsigned TbAxiMstPortDataWidth = 64  ,
    parameter int unsigned TbAxiUserWidth        = 8   ,
    // TB Parameters
    parameter time TbCyclTime                    = 10ns,
    parameter time TbApplTime                    = 2ns ,
    parameter time TbTestTime                    = 8ns
  );

  /*********************
   *  CLOCK GENERATOR  *
   *********************/

  logic clk;
  logic rst_n;
  logic eos;

  clk_rst_gen #(
    .ClkPeriod    (TbCyclTime),
    .RstClkCycles (5       )
  ) i_clk_rst_gen (
    .clk_o (clk  ),
    .rst_no(rst_n)
  );

  /*********
   *  AXI  *
   *********/

  // Master port

  AXI_BUS_DV #(
    .AXI_ADDR_WIDTH(TbAxiAddrWidth       ),
    .AXI_DATA_WIDTH(TbAxiSlvPortDataWidth),
    .AXI_ID_WIDTH  (TbAxiIdWidth         ),
    .AXI_USER_WIDTH(TbAxiUserWidth       )
  ) master_dv (
    .clk_i(clk)
  );

  AXI_BUS #(
    .AXI_ADDR_WIDTH(TbAxiAddrWidth       ),
    .AXI_DATA_WIDTH(TbAxiSlvPortDataWidth),
    .AXI_ID_WIDTH  (TbAxiIdWidth         ),
    .AXI_USER_WIDTH(TbAxiUserWidth       )
  ) master ();

  `AXI_ASSIGN(master, master_dv)

  axi_test::axi_rand_master #(
    .AW            (TbAxiAddrWidth       ),
    .DW            (TbAxiSlvPortDataWidth),
    .IW            (TbAxiIdWidth         ),
    .UW            (TbAxiUserWidth       ),
    .TA            (TbApplTime           ),
    .TT            (TbTestTime           ),
    .MAX_READ_TXNS (8                  ),
    .MAX_WRITE_TXNS(8                  ),
    .AXI_ATOPS     (1'b1               )
  ) master_drv = new (master_dv);

  // Slave port

  AXI_BUS_DV #(
    .AXI_ADDR_WIDTH(TbAxiAddrWidth       ),
    .AXI_DATA_WIDTH(TbAxiMstPortDataWidth),
    .AXI_ID_WIDTH  (TbAxiIdWidth         ),
    .AXI_USER_WIDTH(TbAxiUserWidth       )
  ) slave_dv (
    .clk_i(clk)
  );

  AXI_BUS #(
    .AXI_ADDR_WIDTH(TbAxiAddrWidth       ),
    .AXI_DATA_WIDTH(TbAxiMstPortDataWidth),
    .AXI_ID_WIDTH  (TbAxiIdWidth         ),
    .AXI_USER_WIDTH(TbAxiUserWidth       )
  ) slave ();

  axi_test::axi_rand_slave #(
    .AW(TbAxiAddrWidth       ),
    .DW(TbAxiMstPortDataWidth),
    .IW(TbAxiIdWidth         ),
    .UW(TbAxiUserWidth       ),
    .TA(TbApplTime           ),
    .TT(TbTestTime           )
  ) slave_drv = new (slave_dv);

  `AXI_ASSIGN(slave_dv, slave)

  /*********
   *  DUT  *
   *********/

  axi_dw_converter_intf #(
    .AXI_MAX_READS          (4                  ),
    .AXI_ADDR_WIDTH         (TbAxiAddrWidth       ),
    .AXI_ID_WIDTH           (TbAxiIdWidth         ),
    .AXI_SLV_PORT_DATA_WIDTH(TbAxiSlvPortDataWidth),
    .AXI_MST_PORT_DATA_WIDTH(TbAxiMstPortDataWidth),
    .AXI_USER_WIDTH         (TbAxiUserWidth       )
  ) i_dw_converter (
    .clk_i (clk   ),
    .rst_ni(rst_n ),
    .slv   (master),
    .mst   (slave )
  );

  /*************
   *  DRIVERS  *
   *************/

  // Directed test: a read after a rejected atomic WRAP burst. An AtomicCompare of two beats whose
  // address is aligned to one beat, but not to both, is a WRAP burst [E1.1.3]: the upsizer rejects
  // it and answers on B and R with SLVERR, through one of its read upsizers. The legal read that
  // follows gets the same read upsizer and has to be forwarded to the master port, which the
  // assertion `err_slv_ar_unsupported` of the upsizer checks. An AtomicCompare carries at most 32
  // bytes, so the test needs a slave port of at most 128 bits.
  localparam int unsigned TbAxiSlvPortStrbWidth = TbAxiSlvPortDataWidth / 8;

  typedef axi_test::axi_ax_beat #(.AW(TbAxiAddrWidth), .IW(TbAxiIdWidth), .UW(TbAxiUserWidth))
    ax_beat_t;
  typedef axi_test::axi_w_beat #(.DW(TbAxiSlvPortDataWidth), .UW(TbAxiUserWidth)) w_beat_t;
  typedef axi_test::axi_b_beat #(.IW(TbAxiIdWidth), .UW(TbAxiUserWidth)) b_beat_t;
  typedef axi_test::axi_r_beat #(.DW(TbAxiSlvPortDataWidth), .IW(TbAxiIdWidth),
    .UW(TbAxiUserWidth)) r_beat_t;

  task automatic atop_wrap_then_read();
    automatic ax_beat_t aw = new, ar = new;
    automatic w_beat_t  w;
    automatic b_beat_t  b;
    automatic r_beat_t  r;
    if (2 * TbAxiSlvPortStrbWidth > 32) return;
    $display("Directed test: read after a rejected atomic WRAP burst");

    // AtomicCompare of two beats as wide as the slave port
    aw.ax_id    = '0;
    aw.ax_addr  = TbAxiSlvPortStrbWidth;
    aw.ax_size  = $clog2(TbAxiSlvPortStrbWidth);
    aw.ax_len   = 1;
    aw.ax_burst = axi_pkg::BURST_WRAP;
    aw.ax_cache = axi_pkg::CACHE_MODIFIABLE;
    aw.ax_atop  = axi_pkg::ATOP_ATOMICCMP;
    master_drv.drv.send_aw(aw);
    for (int unsigned i = 0; i < 2; i++) begin
      w        = new;
      w.w_strb = '1;
      w.w_last = (i == 1);
      master_drv.drv.send_w(w);
    end
    master_drv.drv.recv_b(b);
    repeat (2) master_drv.drv.recv_r(r);

    // Legal INCR read of four beats
    ar.ax_id    = 1;
    ar.ax_size  = $clog2(TbAxiSlvPortStrbWidth);
    ar.ax_len   = 3;
    ar.ax_burst = axi_pkg::BURST_INCR;
    ar.ax_cache = axi_pkg::CACHE_MODIFIABLE;
    master_drv.drv.send_ar(ar);
    repeat (4) master_drv.drv.recv_r(r);
  endtask

  initial begin
    eos = 1'b0;

    // Configuration
    slave_drv.reset()                                                                                  ;
    master_drv.reset()                                                                                 ;
    master_drv.add_memory_region({TbAxiAddrWidth{1'b0}}, {TbAxiAddrWidth{1'b1}}, axi_pkg::WTHRU_NOALLOCATE);

    // Wait for the reset before sending requests
    @(posedge rst_n);

    fork
      // Act as a sink
      slave_drv.run()         ;
      master_drv.run(200, 200);
    join_any

    // After the random traffic, whose monitor does not model rejected bursts
    atop_wrap_then_read();

    // Done
    repeat (10) @(posedge clk);
    eos = 1'b1;
  end

  /*************
   *  MONITOR  *
   *************/

  initial begin : proc_monitor
    static tb_axi_dw_pkg::axi_dw_upsizer_monitor #(
      .AxiAddrWidth       (TbAxiAddrWidth       ),
      .AxiMstPortDataWidth(TbAxiMstPortDataWidth),
      .AxiSlvPortDataWidth(TbAxiSlvPortDataWidth),
      .AxiIdWidth         (TbAxiIdWidth         ),
      .AxiUserWidth       (TbAxiUserWidth       ),
      .TimeTest           (TbTestTime           )
    ) monitor = new (master_dv, slave_dv);
    fork
      monitor.run();
      forever begin
        #TbTestTime;
        if(eos) begin
          monitor.print_result();
          $stop()               ;
        end
        @(posedge clk);
      end
    join
  end

// vsim -voptargs=+acc work.tb_axi_dw_upsizer
endmodule : tb_axi_dw_upsizer
