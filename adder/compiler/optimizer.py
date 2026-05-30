"""
Adder ARM Assembly Optimizer

Provides multiple optimization passes for generated ARM Thumb-2 assembly:
1. Peephole Optimization - Local instruction pattern matching
2. Dead Code Elimination - Remove unreachable and unused code
3. Function Inlining - Inline small/single-use functions
4. Constant Folding - Evaluate constants at compile time

All optimizations are toggleable via the OptimizationConfig class.
"""

import re
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class OptimizationConfig:
    """Configuration for which optimizations to enable."""
    peephole: bool = True
    dead_code: bool = True
    function_inlining: bool = True
    constant_folding: bool = True
    # Sub-options
    inline_threshold: int = 10  # Max instructions for inlining
    inline_single_call: bool = True  # Inline functions called only once
    remove_redundant_loads: bool = True
    combine_arithmetic: bool = True
    strength_reduction: bool = True
    eliminate_push_pop: bool = True


@dataclass
class LivenessInfo:
    """Tracks variable liveness for dead code elimination."""
    defined: set[str] = field(default_factory=set)  # Variables assigned
    used: set[str] = field(default_factory=set)     # Variables read
    live_out: set[str] = field(default_factory=set) # Live at block exit


@dataclass
class FunctionInfo:
    """Information about a function for inlining decisions."""
    name: str
    start_line: int
    end_line: int
    instruction_count: int
    call_count: int = 0
    has_recursion: bool = False
    uses_stack_frame: bool = False


class ARMOptimizer:
    """Optimizes ARM Thumb-2 assembly code."""

    def __init__(self, config: Optional[OptimizationConfig] = None):
        self.config = config or OptimizationConfig()
        self.functions: dict[str, FunctionInfo] = {}
        self.labels: set[str] = set()
        self.branch_targets: set[str] = set()

    def optimize_assembly(self, asm_lines: list[str]) -> list[str]:
        """
        Main entry point for assembly optimization.

        Applies enabled optimization passes in order:
        1. Constant folding (on intermediate representation)
        2. Dead code elimination
        3. Peephole optimization
        4. Function inlining

        Args:
            asm_lines: List of assembly instruction strings

        Returns:
            Optimized list of assembly instructions
        """
        lines = asm_lines.copy()

        # Analyze the code first
        self._analyze_code(lines)

        # Apply optimization passes in order
        if self.config.dead_code:
            lines = self.dead_code_pass(lines)

        if self.config.peephole:
            # Run peephole multiple times until no more changes
            changed = True
            max_iterations = 10
            iteration = 0
            while changed and iteration < max_iterations:
                new_lines = self.peephole_pass(lines)
                changed = (new_lines != lines)
                lines = new_lines
                iteration += 1

        if self.config.function_inlining:
            lines = self.inlining_pass(lines)

        return lines

    def _analyze_code(self, lines: list[str]) -> None:
        """Analyze code to gather information for optimization."""
        self.functions.clear()
        self.labels.clear()
        self.branch_targets.clear()

        current_func: Optional[str] = None
        func_start = 0
        instruction_count = 0

        for i, line in enumerate(lines):
            stripped = line.strip()

            # Track labels
            if stripped.endswith(':') and not stripped.startswith('@'):
                label = stripped[:-1]
                self.labels.add(label)

                # Check if this is a function label (not starting with .)
                if not label.startswith('.'):
                    if current_func:
                        # End previous function
                        self.functions[current_func] = FunctionInfo(
                            name=current_func,
                            start_line=func_start,
                            end_line=i - 1,
                            instruction_count=instruction_count
                        )
                    current_func = label
                    func_start = i
                    instruction_count = 0

            # Track branch targets
            branch_match = re.search(r'\b(b|bl|bx|blx|beq|bne|bgt|bge|blt|ble|bhi|bls|bcs|bcc|bmi|bpl|bvs|bvc|cbnz|cbz)\s+(\S+)', stripped)
            if branch_match:
                target = branch_match.group(2)
                self.branch_targets.add(target)

            # Count instructions (non-labels, non-directives, non-comments)
            if stripped and not stripped.endswith(':') and not stripped.startswith('.') and not stripped.startswith('@'):
                instruction_count += 1

            # Track function calls to count call sites
            call_match = re.search(r'\bbl\s+(\w+)', stripped)
            if call_match:
                called_func = call_match.group(1)
                if called_func in self.functions:
                    self.functions[called_func].call_count += 1

        # End last function
        if current_func:
            self.functions[current_func] = FunctionInfo(
                name=current_func,
                start_line=func_start,
                end_line=len(lines) - 1,
                instruction_count=instruction_count
            )

        # Second pass: count calls and detect recursion
        for i, line in enumerate(lines):
            call_match = re.search(r'\bbl\s+(\w+)', line)
            if call_match:
                called_func = call_match.group(1)
                if called_func in self.functions:
                    self.functions[called_func].call_count += 1
                    # Check for recursion
                    for func_name, func_info in self.functions.items():
                        if func_info.start_line <= i <= func_info.end_line:
                            if called_func == func_name:
                                func_info.has_recursion = True

    def peephole_pass(self, lines: list[str]) -> list[str]:
        """
        Apply peephole optimizations to assembly.

        Peephole optimizations look at small windows of instructions
        and apply local transformations.

        Returns:
            Optimized list of assembly instructions
        """
        result = []
        i = 0

        while i < len(lines):
            line = lines[i]
            stripped = line.strip()

            # Skip empty lines, labels, directives, and comments
            if not stripped or stripped.endswith(':') or stripped.startswith('.') or stripped.startswith('@'):
                result.append(line)
                i += 1
                continue

            consumed, optimized = self._apply_peephole(lines, i)
            if optimized is not None:
                result.extend(optimized)
                i += consumed
            else:
                result.append(line)
                i += 1

        return result

    def _apply_peephole(self, lines: list[str], idx: int) -> tuple[int, Optional[list[str]]]:
        """
        Try to apply peephole optimization at the given index.

        Returns:
            (lines_consumed, optimized_lines) or (0, None) if no optimization
        """
        line = lines[idx].strip()

        # Get next non-empty, non-label line
        def get_next(offset: int) -> tuple[int, Optional[str]]:
            j = idx + offset
            while j < len(lines):
                s = lines[j].strip()
                if s and not s.endswith(':') and not s.startswith('@'):
                    return j, s
                j += 1
            return j, None

        next_idx, next_line = get_next(1)

        # 1. Remove redundant loads after stores to same location
        if self.config.remove_redundant_loads:
            # Pattern: str rX, [rY, #N] followed by ldr rX, [rY, #N]
            str_match = re.match(r'str\s+(r\d+),\s*\[([^\]]+)\]', line)
            if str_match and next_line:
                ldr_match = re.match(r'ldr\s+(r\d+),\s*\[([^\]]+)\]', next_line)
                if ldr_match:
                    str_reg, str_loc = str_match.groups()
                    ldr_reg, ldr_loc = ldr_match.groups()
                    if str_loc == ldr_loc:
                        # Remove the load, optionally add mov if registers differ
                        if str_reg == ldr_reg:
                            return 2, [lines[idx]]  # Just keep the store
                        else:
                            return 2, [lines[idx], f"    mov {ldr_reg}, {str_reg}"]

        # 2. Combine consecutive adds/subs
        if self.config.combine_arithmetic:
            # Pattern: add rX, rX, #N1 followed by add rX, rX, #N2
            add_match = re.match(r'(adds?)\s+(r\d+),\s*(r\d+),\s*#(-?\d+)', line)
            if add_match and next_line:
                op1, reg1, reg1_src, imm1 = add_match.groups()
                if reg1 == reg1_src:  # add rX, rX, #N
                    add_match2 = re.match(r'(adds?)\s+(r\d+),\s*(r\d+),\s*#(-?\d+)', next_line)
                    if add_match2:
                        op2, reg2, reg2_src, imm2 = add_match2.groups()
                        if reg1 == reg2 == reg2_src:
                            combined = int(imm1) + int(imm2)
                            if combined == 0:
                                return 2, []  # Both cancel out
                            elif -256 <= combined <= 255:
                                return 2, [f"    adds {reg1}, {reg1}, #{combined}"]
                            elif combined > 0 and combined <= 4095:
                                return 2, [f"    add.w {reg1}, {reg1}, #{combined}"]

            # Pattern: sub rX, rX, #N1 followed by sub rX, rX, #N2
            sub_match = re.match(r'(subs?)\s+(r\d+),\s*(r\d+),\s*#(-?\d+)', line)
            if sub_match and next_line:
                op1, reg1, reg1_src, imm1 = sub_match.groups()
                if reg1 == reg1_src:
                    sub_match2 = re.match(r'(subs?)\s+(r\d+),\s*(r\d+),\s*#(-?\d+)', next_line)
                    if sub_match2:
                        op2, reg2, reg2_src, imm2 = sub_match2.groups()
                        if reg1 == reg2 == reg2_src:
                            combined = int(imm1) + int(imm2)
                            if combined == 0:
                                return 2, []
                            elif combined > 0 and combined <= 255:
                                return 2, [f"    subs {reg1}, {reg1}, #{combined}"]
                            elif combined > 0 and combined <= 4095:
                                return 2, [f"    sub.w {reg1}, {reg1}, #{combined}"]

            # Pattern: add followed by sub (or vice versa) on same register
            if add_match and next_line:
                op1, reg1, reg1_src, imm1 = add_match.groups()
                if reg1 == reg1_src:
                    sub_match2 = re.match(r'(subs?)\s+(r\d+),\s*(r\d+),\s*#(-?\d+)', next_line)
                    if sub_match2:
                        op2, reg2, reg2_src, imm2 = sub_match2.groups()
                        if reg1 == reg2 == reg2_src:
                            combined = int(imm1) - int(imm2)
                            if combined == 0:
                                return 2, []
                            elif combined > 0 and combined <= 255:
                                return 2, [f"    adds {reg1}, {reg1}, #{combined}"]
                            elif combined < 0 and combined >= -255:
                                return 2, [f"    subs {reg1}, {reg1}, #{-combined}"]

        # 3. Replace mov rX, #0 with eor rX, rX, rX (smaller encoding)
        # Note: On Thumb-2, movs r0, #0 is already optimal (2 bytes)
        # but eor can be useful in some contexts
        # Actually, for Thumb-2 movs is fine, so we skip this optimization
        # as it's more relevant for full ARM mode

        # 4. Eliminate redundant push/pop pairs
        if self.config.eliminate_push_pop:
            # Pattern: push {rX} followed immediately by pop {rX}
            push_match = re.match(r'push\s*\{([^}]+)\}', line)
            if push_match and next_line:
                pop_match = re.match(r'pop\s*\{([^}]+)\}', next_line)
                if pop_match:
                    push_regs = push_match.group(1).strip()
                    pop_regs = pop_match.group(1).strip()
                    if push_regs == pop_regs:
                        # Remove both push and pop - they cancel out
                        return next_idx - idx + 1, []

            # Pattern: push {rX} ... pop {rY} where rX == rY and no intervening use
            # This is more complex - need data flow analysis

        # 5. Strength reduction: multiply by power of 2 -> shift
        if self.config.strength_reduction:
            # Pattern: ldr rX, =N followed by mul rY, rZ, rX where N is power of 2
            ldr_match = re.match(r'ldr\s+(r\d+),\s*=(\d+)', line)
            if ldr_match and next_line:
                const_reg, const_val = ldr_match.groups()
                const_int = int(const_val)

                mul_match = re.match(r'mul\s+(r\d+),\s*(r\d+),\s*(r\d+)', next_line)
                if mul_match:
                    dst, src1, src2 = mul_match.groups()
                    # Check if const_reg is used in multiply
                    if const_reg == src1 or const_reg == src2:
                        if self._is_power_of_2(const_int):
                            shift = self._log2(const_int)
                            other_reg = src2 if const_reg == src1 else src1
                            return 2, [f"    lsl {dst}, {other_reg}, #{shift}"]

            # Direct mul with immediate (if loaded constant)
            # Pattern: movs rX, #N followed by mul where N is power of 2
            movs_match = re.match(r'movs?\s+(r\d+),\s*#(\d+)', line)
            if movs_match and next_line:
                const_reg, const_val = movs_match.groups()
                const_int = int(const_val)

                mul_match = re.match(r'mul\s+(r\d+),\s*(r\d+),\s*(r\d+)', next_line)
                if mul_match:
                    dst, src1, src2 = mul_match.groups()
                    if const_reg == src1 or const_reg == src2:
                        if self._is_power_of_2(const_int):
                            shift = self._log2(const_int)
                            other_reg = src2 if const_reg == src1 else src1
                            return 2, [f"    lsl {dst}, {other_reg}, #{shift}"]

        # 6. Remove mov rX, rX (nop)
        mov_match = re.match(r'movs?\s+(r\d+),\s*(r\d+)$', line.rstrip())
        if mov_match:
            dst, src = mov_match.groups()
            if dst == src:
                return 1, []  # Remove the instruction

        # 7. Optimize immediate loads followed by operations
        # Pattern: movs r0, #0 can sometimes be optimized based on context

        return 0, None

    def _is_power_of_2(self, n: int) -> bool:
        """Check if n is a power of 2."""
        return n > 0 and (n & (n - 1)) == 0

    def _log2(self, n: int) -> int:
        """Return log base 2 of n (assumes n is power of 2)."""
        result = 0
        while n > 1:
            n >>= 1
            result += 1
        return result

    def dead_code_pass(self, lines: list[str]) -> list[str]:
        """
        Remove dead code from assembly.

        This includes:
        - Unreachable code after unconditional branches/returns
        - Unused variable assignments (with liveness analysis)
        - Empty basic blocks

        Returns:
            List of assembly instructions with dead code removed
        """
        # First pass: mark reachable code
        reachable = self._find_reachable_code(lines)

        # Second pass: track liveness for unused assignments
        liveness = self._analyze_liveness(lines)

        result = []
        i = 0
        in_unreachable = False

        while i < len(lines):
            line = lines[i]
            stripped = line.strip()

            # Labels are always kept (they might be branch targets)
            if stripped.endswith(':'):
                result.append(line)
                label = stripped[:-1]
                # Check if this label is a branch target
                if label in self.branch_targets or not label.startswith('.'):
                    in_unreachable = False
                i += 1
                continue

            # Directives are always kept
            if stripped.startswith('.') or not stripped or stripped.startswith('@'):
                result.append(line)
                i += 1
                continue

            # Skip unreachable code
            if in_unreachable:
                i += 1
                continue

            # Check for unconditional branch/return
            if re.match(r'(b\s+\S+|bx\s+lr|pop\s*\{[^}]*pc\})\s*$', stripped):
                result.append(line)
                in_unreachable = True
                i += 1
                continue

            # Check for dead stores (store to location never read)
            # This is complex for registers; simplified version here
            if self._is_dead_store(lines, i, liveness):
                i += 1
                continue

            result.append(line)
            i += 1

        return result

    def _find_reachable_code(self, lines: list[str]) -> set[int]:
        """Find all reachable lines of code using control flow analysis."""
        reachable = set()
        worklist = [0]  # Start from first line
        label_to_line: dict[str, int] = {}

        # Build label -> line mapping
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.endswith(':'):
                label_to_line[stripped[:-1]] = i

        while worklist:
            idx = worklist.pop()
            if idx in reachable or idx >= len(lines):
                continue

            reachable.add(idx)
            line = lines[idx].strip()

            # Skip empty lines, comments, directives
            if not line or line.startswith('@') or line.startswith('.') or line.endswith(':'):
                worklist.append(idx + 1)
                continue

            # Check for branches
            branch_match = re.match(r'(b|beq|bne|bgt|bge|blt|ble|bhi|bls|bcs|bcc|bmi|bpl|bvs|bvc|cbnz|cbz)\s+(\S+)', line)
            if branch_match:
                branch_type, target = branch_match.groups()
                if target in label_to_line:
                    worklist.append(label_to_line[target])
                # Conditional branches also fall through
                if branch_type != 'b':
                    worklist.append(idx + 1)
            elif re.match(r'(bx\s+lr|pop\s*\{[^}]*pc\})', line):
                # Return - don't add successor
                pass
            else:
                # Regular instruction - fall through
                worklist.append(idx + 1)

        return reachable

    def _analyze_liveness(self, lines: list[str]) -> dict[int, LivenessInfo]:
        """Analyze liveness of registers at each line."""
        liveness: dict[int, LivenessInfo] = {}

        # Simplified backward liveness analysis
        live = set()  # Currently live registers

        for i in range(len(lines) - 1, -1, -1):
            line = lines[i].strip()
            info = LivenessInfo()
            info.live_out = live.copy()

            # Parse instruction to find defs and uses
            defs, uses = self._get_defs_uses(line)
            info.defined = defs
            info.used = uses

            # Update live set: remove defs, add uses
            live = (live - defs) | uses
            liveness[i] = info

        return liveness

    def _get_defs_uses(self, line: str) -> tuple[set[str], set[str]]:
        """Get defined and used registers for an instruction."""
        defs = set()
        uses = set()

        # Common patterns for ARM instructions
        # This is simplified - a full implementation would parse each instruction type

        # mov/movs rX, rY or mov rX, #imm
        mov_match = re.match(r'movs?\s+(r\d+),\s*(r\d+|#\S+)', line)
        if mov_match:
            defs.add(mov_match.group(1))
            if mov_match.group(2).startswith('r'):
                uses.add(mov_match.group(2))
            return defs, uses

        # ldr rX, [rY, #offset] or ldr rX, =label
        ldr_match = re.match(r'ldr\s+(r\d+),\s*(\[([^\]]+)\]|=\S+)', line)
        if ldr_match:
            defs.add(ldr_match.group(1))
            if ldr_match.group(3):
                # Extract base register from [rY, #offset]
                base_match = re.match(r'(r\d+)', ldr_match.group(3))
                if base_match:
                    uses.add(base_match.group(1))
            return defs, uses

        # str rX, [rY, #offset]
        str_match = re.match(r'str\s+(r\d+),\s*\[([^\]]+)\]', line)
        if str_match:
            uses.add(str_match.group(1))
            base_match = re.match(r'(r\d+)', str_match.group(2))
            if base_match:
                uses.add(base_match.group(1))
            return defs, uses

        # add/sub/mul etc: op rX, rY, rZ or op rX, rY, #imm
        arith_match = re.match(r'(adds?|subs?|muls?|ands?|orrs?|eors?|lsls?|lsrs?|asrs?)\s+(r\d+),\s*(r\d+),\s*(r\d+|#\S+)', line)
        if arith_match:
            defs.add(arith_match.group(2))
            uses.add(arith_match.group(3))
            if arith_match.group(4).startswith('r'):
                uses.add(arith_match.group(4))
            return defs, uses

        # push/pop
        push_match = re.match(r'push\s*\{([^}]+)\}', line)
        if push_match:
            for reg in re.findall(r'r\d+|lr|pc', push_match.group(1)):
                uses.add(reg)
            return defs, uses

        pop_match = re.match(r'pop\s*\{([^}]+)\}', line)
        if pop_match:
            for reg in re.findall(r'r\d+|lr|pc', pop_match.group(1)):
                defs.add(reg)
            return defs, uses

        # bl - uses r0-r3, defines r0
        if re.match(r'bl\s+', line):
            uses.update(['r0', 'r1', 'r2', 'r3'])
            defs.add('r0')
            return defs, uses

        return defs, uses

    def _is_dead_store(self, lines: list[str], idx: int, liveness: dict[int, LivenessInfo]) -> bool:
        """Check if the store at idx is dead (value never used)."""
        if idx not in liveness:
            return False

        info = liveness[idx]

        # If this defines a register that's not live after this point,
        # and it's not a store to memory, it might be dead
        # For now, be conservative and only remove obvious cases

        line = lines[idx].strip()

        # Don't remove stores to memory - they might have side effects
        if re.match(r'str', line):
            return False

        # Check if any defined register is not used afterwards
        for reg in info.defined:
            if reg not in info.live_out and reg not in info.used:
                # This register is defined but not used - potential dead code
                # But be conservative with special registers
                if reg in ('r0', 'lr', 'pc', 'sp', 'r7'):
                    return False
                # For now, don't remove - too risky without full analysis
                return False

        return False

    def inlining_pass(self, lines: list[str]) -> list[str]:
        """
        Inline small functions or functions called only once.

        Returns:
            Assembly with inlined functions
        """
        if not self.functions:
            self._analyze_code(lines)

        # Find candidates for inlining
        candidates = []
        for name, info in self.functions.items():
            if self.should_inline(info):
                candidates.append(name)

        if not candidates:
            return lines

        result = lines.copy()

        # Inline each candidate
        for func_name in candidates:
            result = self._inline_function_calls(result, func_name)

        return result

    def should_inline(self, func: FunctionInfo) -> bool:
        """
        Determine if a function should be inlined.

        Criteria:
        - Small function (< threshold instructions)
        - Called only once (if inline_single_call enabled)
        - No recursion
        - Simple stack frame (or no frame)

        Args:
            func: Function information

        Returns:
            True if function should be inlined
        """
        # Never inline recursive functions
        if func.has_recursion:
            return False

        # Don't inline main or interrupt handlers
        if func.name in ('main', '_start') or func.name.startswith('__'):
            return False

        # Inline if small enough
        if func.instruction_count <= self.config.inline_threshold:
            return True

        # Inline if called only once
        if self.config.inline_single_call and func.call_count == 1:
            return True

        return False

    def inline_function(self, call_site_lines: list[str], call_idx: int,
                        func_body: list[str], func_name: str) -> list[str]:
        """
        Inline a function at a specific call site.

        Args:
            call_site_lines: The lines containing the call
            call_idx: Index of the bl instruction
            func_body: The function body to inline
            func_name: Name of the function being inlined

        Returns:
            New list of lines with function inlined
        """
        result = call_site_lines[:call_idx]

        # Generate unique suffix for labels to avoid conflicts
        suffix = f"_inline_{func_name}_{call_idx}"

        # Process function body for inlining
        for line in func_body:
            stripped = line.strip()

            # Skip function label and .size/.type directives
            if stripped == f"{func_name}:" or stripped.startswith('.size') or stripped.startswith('.type'):
                continue

            # Skip push/pop of frame (simplified - real implementation needs better detection)
            if re.match(r'push\s*\{[^}]*r7[^}]*lr[^}]*\}', stripped):
                continue
            if re.match(r'pop\s*\{[^}]*r7[^}]*pc[^}]*\}', stripped):
                continue

            # Rename local labels to avoid conflicts
            if stripped.endswith(':') and stripped.startswith('.'):
                label = stripped[:-1]
                result.append(f"{label}{suffix}:")
                continue

            # Update branch targets
            branch_match = re.match(r'(\s*)(b|beq|bne|bgt|bge|blt|ble|bhi|bls|cbnz|cbz)\s+(\.\S+)', stripped)
            if branch_match:
                indent, branch, target = branch_match.groups()
                result.append(f"{indent}{branch} {target}{suffix}")
                continue

            # Replace bx lr with branch to after call site
            if stripped == 'bx lr':
                # Skip the return - control will fall through
                continue

            result.append(line)

        # Add rest of original code (after the call)
        result.extend(call_site_lines[call_idx + 1:])

        return result

    def _inline_function_calls(self, lines: list[str], func_name: str) -> list[str]:
        """Replace all calls to func_name with inlined body."""
        if func_name not in self.functions:
            return lines

        func_info = self.functions[func_name]

        # Extract function body
        func_body = lines[func_info.start_line:func_info.end_line + 1]

        result = []
        i = 0
        inline_count = 0

        while i < len(lines):
            line = lines[i]
            stripped = line.strip()

            # Check for call to this function
            if re.match(rf'bl\s+{re.escape(func_name)}\s*$', stripped):
                # Inline the function
                inlined = self._prepare_inline_body(func_body, func_name, inline_count)
                result.extend(inlined)
                inline_count += 1
            else:
                result.append(line)

            i += 1

        return result

    def _prepare_inline_body(self, func_body: list[str], func_name: str, count: int) -> list[str]:
        """Prepare function body for inlining with unique labels."""
        result = []
        suffix = f"_inl{count}"

        for line in func_body:
            stripped = line.strip()

            # Skip function entry
            if stripped == f"{func_name}:":
                result.append(f"    @ inlined: {func_name}")
                continue

            # Skip directives
            if stripped.startswith('.global') or stripped.startswith('.type') or stripped.startswith('.size'):
                continue

            # Skip prologue (simplified detection)
            if re.match(r'push\s*\{[^}]*lr[^}]*\}', stripped):
                continue
            if re.match(r'mov\s+r7,\s*sp', stripped):
                continue

            # Skip epilogue
            if re.match(r'pop\s*\{[^}]*pc[^}]*\}', stripped):
                continue
            if stripped == 'bx lr':
                continue

            # Rename local labels
            if stripped.endswith(':') and stripped.startswith('.'):
                label = stripped[:-1]
                result.append(f"{label}{suffix}:")
                continue

            # Update branch targets to local labels
            new_line = line
            for match in re.finditer(r'(\.\w+)', stripped):
                local_label = match.group(1)
                if local_label.startswith('.L') or local_label.startswith('.'):
                    new_line = new_line.replace(local_label, f"{local_label}{suffix}")

            result.append(new_line)

        return result


def fold_expr(expr_str: str) -> Optional[int]:
    """
    Attempt to evaluate a constant expression at compile time.

    Args:
        expr_str: String representation of the expression

    Returns:
        Evaluated integer value, or None if not a constant expression
    """
    # Simple constant folding for assembly immediates
    # This handles basic arithmetic on immediates

    # Pattern: #N op #M
    match = re.match(r'#(-?\d+)\s*([+\-*/])\s*#(-?\d+)', expr_str)
    if match:
        left, op, right = match.groups()
        left, right = int(left), int(right)

        if op == '+':
            return left + right
        elif op == '-':
            return left - right
        elif op == '*':
            return left * right
        elif op == '/' and right != 0:
            return left // right

    # Just a constant
    match = re.match(r'#(-?\d+)$', expr_str.strip())
    if match:
        return int(match.group(1))

    return None


def constant_fold_pass(lines: list[str]) -> list[str]:
    """
    Apply constant folding to assembly instructions.

    This evaluates constant expressions at compile time.

    Args:
        lines: Assembly instruction lines

    Returns:
        Lines with constants folded
    """
    result = []

    # Track known constant values in registers
    reg_values: dict[str, int] = {}

    for line in lines:
        stripped = line.strip()

        # Skip non-instructions
        if not stripped or stripped.endswith(':') or stripped.startswith('.') or stripped.startswith('@'):
            result.append(line)
            # Labels invalidate our knowledge
            if stripped.endswith(':'):
                reg_values.clear()
            continue

        # Track movs rX, #imm
        mov_match = re.match(r'movs?\s+(r\d+),\s*#(-?\d+)', stripped)
        if mov_match:
            reg, val = mov_match.groups()
            reg_values[reg] = int(val)
            result.append(line)
            continue

        # Track ldr rX, =imm
        ldr_imm_match = re.match(r'ldr\s+(r\d+),\s*=(-?\d+)', stripped)
        if ldr_imm_match:
            reg, val = ldr_imm_match.groups()
            reg_values[reg] = int(val)
            result.append(line)
            continue

        # Try to fold add rX, rY, rZ where both rY, rZ are known
        add_match = re.match(r'adds?\s+(r\d+),\s*(r\d+),\s*(r\d+)', stripped)
        if add_match:
            dst, src1, src2 = add_match.groups()
            if src1 in reg_values and src2 in reg_values:
                val = reg_values[src1] + reg_values[src2]
                if -256 <= val <= 255:
                    result.append(f"    movs {dst}, #{val}")
                    reg_values[dst] = val
                    continue
                elif 0 <= val <= 65535:
                    result.append(f"    movw {dst}, #{val}")
                    reg_values[dst] = val
                    continue
            # Invalidate dst since we don't know its value
            reg_values.pop(dst, None)

        # Similarly for sub, mul, etc. (simplified)
        sub_match = re.match(r'subs?\s+(r\d+),\s*(r\d+),\s*(r\d+)', stripped)
        if sub_match:
            dst, src1, src2 = sub_match.groups()
            if src1 in reg_values and src2 in reg_values:
                val = reg_values[src1] - reg_values[src2]
                if -256 <= val <= 255:
                    result.append(f"    movs {dst}, #{val}")
                    reg_values[dst] = val
                    continue
            reg_values.pop(dst, None)

        # Any other instruction that defines a register invalidates our knowledge
        # (simplified - would need full instruction parsing)
        for reg in list(reg_values.keys()):
            if re.search(rf'\b{reg}\b', stripped.split(',')[0] if ',' in stripped else ''):
                reg_values.pop(reg, None)

        result.append(line)

    return result


# Convenience function - main entry point
def optimize_assembly(asm_lines: list[str],
                     config: Optional[OptimizationConfig] = None) -> list[str]:
    """
    Main entry point for assembly optimization.

    Args:
        asm_lines: List of assembly instruction strings
        config: Optional optimization configuration

    Returns:
        Optimized list of assembly instructions
    """
    optimizer = ARMOptimizer(config)
    return optimizer.optimize_assembly(asm_lines)


def peephole_pass(lines: list[str]) -> list[str]:
    """
    Apply peephole optimizations to assembly.

    Standalone function for convenience.

    Args:
        lines: Assembly instruction lines

    Returns:
        Optimized lines
    """
    optimizer = ARMOptimizer()
    return optimizer.peephole_pass(lines)


def dead_code_pass(lines: list[str]) -> list[str]:
    """
    Remove dead code from assembly.

    Standalone function for convenience.

    Args:
        lines: Assembly instruction lines

    Returns:
        Lines with dead code removed
    """
    optimizer = ARMOptimizer()
    return optimizer.dead_code_pass(lines)
