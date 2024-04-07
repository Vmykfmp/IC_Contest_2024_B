module Bicubic (
input CLK,
input RST,
input [6:0] V0,
input [6:0] H0,
input [4:0] SW,
input [4:0] SH,
input [5:0] TW,
input [5:0] TH,
output reg DONE);

`define state_bit 3


//==============================================//
//                  Parameter                   //
//==============================================//

parameter IDLE = `state_bit'd0;
parameter FILL = `state_bit'd1;
parameter UPDT = `state_bit'd2;
parameter CALH = `state_bit'd3;
parameter CALV = `state_bit'd4;
parameter SRAM = `state_bit'd5;
parameter FIN  = `state_bit'd6;

integer row, col;

//==============================================//
//                  Register                    //
//==============================================//
// FSM reg
reg [(`state_bit) - 1:0] state, state_next;
reg [(`state_bit) - 1:0] state_d1, state_d2;
// cnt reg
reg [ 4 - 1: 0] cnt, cnt_d1, cnt_d2;
reg [ 6 - 1: 0] cnt_i, cnt_i_d1;
reg [ 6 - 1: 0] cnt_j, cnt_j_d1;
// flag reg
reg x_move_flag;
reg y_move_flag;
reg sram_flag;

// input reg
reg [7 - 1: 0] H0_reg, V0_reg;
reg [5 - 1: 0] SW_reg, SH_reg;
reg [6 - 1: 0] SW_ext, SH_ext;
reg [6 - 1: 0] TW_reg, TH_reg;
// SRAM reg
reg  [14 - 1: 0] sram_addr;
wire [ 8 - 1: 0] sram_dout;
reg  [ 8 - 1: 0] sram_din;
reg              sram_wen;
// ROM reg
reg  [ 6 - 1: 0] rom_i, rom_i_d1;
reg  [ 6 - 1: 0] rom_j, rom_j_d1;
reg  [14 - 1: 0] rom_addr;
wire [ 8 - 1: 0] rom_dout;
// window reg
reg [8 - 1: 0] window [0:3][0:3];
// interpolation reg
reg [5:0] x_accu;
reg [5:0] y_accu;
reg signed [10 - 1: 0] p [0:3];
reg signed [12 - 1: 0] coef_a;
reg signed [12 - 1: 0] coef_b;
reg signed [12 - 1: 0] coef_c;
reg signed [12 - 1: 0] coef_d;
reg signed [ 8 - 1: 0] nume;
reg signed [ 8 - 1: 0] deno;
reg signed [10 - 1: 0] intp_result;
reg signed [10 - 1: 0] intp_result_relu;
reg signed [10 - 1: 0] intp_reg [0:3];

//==============================================//
//                  FSM Block                   //
//==============================================//
// main FSM
always @(*) begin
    case (state)
        IDLE: begin
            if(~DONE) state_next = FILL;
            else      state_next = IDLE;
        end
        FILL: begin
            if(cnt == 4'd11) state_next = UPDT;
            else             state_next = FILL;
        end
        UPDT: begin
            if(cnt == 4'd15) state_next = CALV;
            else             state_next = UPDT;
        end
        CALH: begin
            if(cnt == 4'd15) state_next = CALV;
            else             state_next = CALH;
        end
        CALV: begin
            state_next = SRAM;
        end
        SRAM: begin
            if(cnt_i == TW_reg) begin
                if(cnt_j == TH_reg) state_next = FIN;
                else                state_next = FILL;
            end
            else if(x_move_flag)    state_next = UPDT;
            else                    state_next = CALH;
        end
        FIN: begin
            state_next = IDLE;
        end
        default: state_next = IDLE;
    endcase
end

always @(posedge CLK or posedge RST) begin
    if(RST) state <= IDLE;
    else    state <= state_next;
end
always @(posedge CLK or posedge RST) begin
    if(RST) state_d1 <= IDLE;
    else    state_d1 <= state;
end
always @(posedge CLK or posedge RST) begin
    if(RST) state_d2 <= IDLE;
    else    state_d2 <= state_d1;
end
//==============================================//
//                Counter Block                 //
//==============================================//
// counter unit
always @(posedge CLK or posedge RST) begin
    if(RST) cnt <= 'b0;
    else begin
        if(state == FILL)      cnt      <= cnt      + 1'd1;
        else if(state == UPDT) cnt[1:0] <= cnt[1:0] + 1'd1;
        else if(state == CALH) cnt[1:0] <= cnt[1:0] + 1'd1;
        else if(state == SRAM) cnt      <= (cnt_i == TW_reg) ? 'b0 : cnt; 
    end
end
always @(posedge CLK or posedge RST) begin
    if(RST) cnt_d1 <= 'b0;
    else begin
        if(state == IDLE) cnt_d1 <= 'b0;
        else              cnt_d1 <= cnt;
    end
end
always @(posedge CLK or posedge RST) begin
    if(RST) cnt_d2 <= 'b0;
    else    cnt_d2 <= cnt_d1;
end

// counter i
always @(posedge CLK or posedge RST) begin
    if(RST) cnt_i <= 'b0;
    else begin
        if(state == SRAM) begin
            if(cnt_i == TW_reg) cnt_i <= 'b0;
            else                cnt_i <= cnt_i + 1'd1;
        end     
    end
end
always @(posedge CLK or posedge RST) begin
    if(RST) cnt_i_d1 <= 'b0;
    else begin
        if(state == IDLE) cnt_i_d1 <= 'b0;
        else              cnt_i_d1 <= cnt_i;
    end
end

// counter j
always @(posedge CLK or posedge RST) begin
    if(RST) cnt_j <= 'b0;
    else begin
        if(state == SRAM) begin
            if(cnt_i == TW_reg) cnt_j <= cnt_j + 1'd1;
            else                cnt_j <= cnt_j;
        end          
        else if(state == FIN)   cnt_j <= 'b0;
    end
end
always @(posedge CLK or posedge RST) begin
    if(RST) cnt_j_d1 <= 'b0;
    else    cnt_j_d1 <= cnt_j;
end
//==============================================//
//                  Flag Block                  //
//==============================================//
always @(*) begin
    // x_move_flag = (x_accu >= TW_reg);
    x_move_flag = (x_accu >= TW_reg - SW_reg);
    // x_move_flag = (x_accu < SW_reg);
end
always @(*) begin
    // y_move_flag = (y_accu >= TH_reg);
    y_move_flag = (y_accu >= TH_reg - SH_reg);
end
// sram write flag
always @(posedge CLK or posedge RST) begin
    if(RST) sram_flag <= 'b0;
    else begin
        if(state == IDLE)         sram_flag <= 'b0;
        else if(cnt_d1 == 14'd16) sram_flag <= 'b1;
        // if(y_accu >= TH_reg) y_move_flag <= 1'b1;
        // else                 y_move_flag <= 1'b0;
    end
end
//==============================================//
//                 Input Block                  //
//==============================================//
always @(posedge CLK or posedge RST) begin
    if(RST) begin
        V0_reg <= 'b0;
        H0_reg <= 'b0;
        SW_reg <= 'b0;
        SH_reg <= 'b0;
        SW_ext <= 'b0;
        SH_ext <= 'b0;
        TW_reg <= 'b0;
        TH_reg <= 'b0;
    end
    else begin
        if(~DONE) begin
            V0_reg <= V0 - 1;
            H0_reg <= H0 - 1;
            SW_reg <= SW - 1;
            SH_reg <= SH - 1;
            SW_ext <= SW + 1;
            SH_ext <= SH + 1;
            TW_reg <= TW - 1;
            TH_reg <= TH - 1;
        end
    end
end
//==============================================//
//                Window Block                  //
//==============================================//
always @(posedge CLK or posedge RST) begin
    if(RST) begin
        for(row = 0; row < 4; row = row + 1)
            for(col = 0; col < 4; col = col + 1)
                window[col][row] <= 'b0;
    end
    else begin
        // if(state == UPDT | state_d1 == UPDT) begin
        if(state_d1 == UPDT) begin
            for(col = 0; col < 4; col = col + 1)
                if(cnt_d1[1:0] == col) begin
                    window[col][3] <= rom_dout;
                    for(row = 0; row < 3; row = row + 1)
                        window[col][row] <= window[col][row + 1];
                end
        end
        else if(state_d1 == FILL) window[cnt_d1[1:0]][cnt_d1[3:2] + 1] <= rom_dout;
    end
end
//==============================================//
//            Interpolation Block               //
//==============================================//
// X accumulation
always @(posedge CLK or posedge RST) begin
    if(RST) x_accu <= 'b0;
    else begin
        case(state)
            FILL: x_accu <= 'b0;
            SRAM: begin
                if(x_move_flag) x_accu <= x_accu + SW_reg - TW_reg;
                else            x_accu <= x_accu + SW_reg;
            end
            default: x_accu <= x_accu;
        endcase
    end
end
// Y accumulation
always @(posedge CLK or posedge RST) begin
    if(RST) y_accu <= 'b0;
    else begin
        case(state_d1)
            IDLE: y_accu <= 'b0;
            SRAM: begin
                if(cnt_i_d1 == TW_reg) begin
                    if(y_move_flag) y_accu <= y_accu + SH_reg - TH_reg;
                    else            y_accu <= y_accu + SH_reg;
                end
            end
            default: y_accu <= y_accu;
        endcase
    end
end
// interpolation p select
always @(*) begin
    p[0] = 'b0;
    p[1] = 'b0;
    p[2] = 'b0;
    p[3] = 'b0;

    if(state_d2 == UPDT | state_d2 == CALH) begin
        for(col = 0; col < 4; col = col + 1) 
            if(cnt_d2[1:0] == col) begin
                for(row = 0; row < 4; row = row + 1) 
                    p[row] = window[col][row];
            end
    end
    else begin
        for(col = 0; col < 4; col = col + 1)
            p[col] = intp_reg[col];
    end
end
// interpolation coefficient compute
always @(*) begin
    coef_a =   - p[0] + (3 * p[1]) - (3 * p[2]) + p[3];
    coef_b = 2 * p[0] - (5 * p[1]) + (4 * p[2]) - p[3];
    coef_c =   - p[0] + p[2];
    coef_d = 2 * p[1]; 
end

always @(*) begin
    // if(state_d2 == UPDT) nume = x_accu;
    // else                 nume = y_accu;  
    if(state_d2 == CALV) nume = y_accu;
    else                 nume = x_accu;
end

always @(*) begin
    // if(state_d2 == UPDT) deno = TW_reg;
    // else                 deno = TH_reg;
    if(state_d2 == CALV) deno = TH_reg;
    else                 deno = TW_reg;
end

always @(*) begin 
    intp_result = (coef_a * nume * nume * nume + 
                   coef_b * nume * nume * deno + 
                   coef_c * nume * deno * deno +
                   coef_d * deno * deno * deno +
                   ((2 * deno * deno * deno) >>> 1)) / 
                  (2 * deno * deno * deno);
end

always @(*) begin
    intp_result_relu = (intp_result > 0) ? intp_result : 0;
end

always @(posedge CLK or posedge RST) begin
    if(RST) begin
        for(col = 0; col < 4; col = col + 1) intp_reg[col] <= 'b0;
    end
    else begin
        // if(state_d2 == UPDT | state_d2 == CALH) intp_reg[cnt_d2[1:0]] <= intp_result;
        if(state_d2 == UPDT | state_d2 == CALH) intp_reg[cnt_d2[1:0]] <= intp_result_relu;
    end
end

//==============================================//
//                Output Block                  //
//==============================================//
always @(posedge CLK or posedge RST) begin
    if(RST) DONE <= 'b0;
    // else    DONE <= (cnt_test[13:2] == SW_ext & state != IDLE);
    else    DONE <= (state == FIN);
end
//==============================================//
//                Memory Block                  //
//==============================================//
// ROM ADDR
always @(posedge CLK or posedge RST) begin
    if(RST) rom_i <= 'b0;
    else begin
        // if(state == FILL) rom_i <= 'b0;
        if(state == SRAM) begin
            if(rom_i == SW_reg)  rom_i <= 'b0;
            else if(x_move_flag) rom_i <= rom_i + 1'd1;  
            else                 rom_i <= rom_i;          
            // if(x_move_flag) begin
            //     if(rom_i == SW_reg) rom_i <= 'b0;
            //     else                rom_i <= rom_i + 1'd1;
            // end
            // else            rom_i <= rom_i;
        end
    end
end
always @(posedge CLK or posedge RST) begin
    if(RST) rom_j <= 'b0;
    else begin
        // if(state == IDLE) rom_j <= 'b0;
        if(state == SRAM & cnt_i == TW_reg) begin
            if(rom_j == SH_reg)  rom_j <= 'b0;
            else if(y_move_flag) rom_j <= rom_j + 1'd1;
            else                 rom_j <= rom_j;            
            // if(y_move_flag) begin
            //     if(rom_j == SH_reg) rom_j <= 'b0;
            //     else                rom_j <= rom_j + 1'd1;
            // end
            // else            rom_j <= rom_j;
        end
    end
end

always @(*) begin
    // rom_addr = (H0_reg + cnt[3:2]) + (V0_reg + cnt[1:0] + cnt_j) * 100;
    rom_addr = (H0_reg + cnt[3:2] + rom_i) + (V0_reg + cnt[1:0] + rom_j) * 100;
end
// SRAM ADDR
always @(*) begin
    sram_addr = cnt_i_d1 + cnt_j_d1 * (TW_reg + 1);
end
// SRAM DIN
always @(*) begin
    // sram_din = intp_result;
    sram_din = intp_result_relu;
end
// SRAM WEN
always @(*) begin
    sram_wen = ~(state_d1 == SRAM);
end

ImgROM u_ImgROM (.Q(rom_dout), .CLK(CLK), .CEN(1'b0), .A(rom_addr));
ResultSRAM u_ResultSRAM (.Q(sram_dout), .CLK(CLK), .CEN(1'b0), .WEN(sram_wen), .A(sram_addr), .D(sram_din));

endmodule


