
SECTIONS {
 .plt 0 : { BYTE(0) }
 .init.plt 0 : { BYTE(0) }
 .text.ftrace_trampoline 0 : { BYTE(0) }
 .initcalls : {
  *(.initcalls._start)
  KEEP(*(.initcall0.init*)) KEEP(*(.initcall0s.init*))
  KEEP(*(.initcall1.init*)) KEEP(*(.initcall1s.init*))
  KEEP(*(.initcall2.init*)) KEEP(*(.initcall2s.init*))
  KEEP(*(.initcall3.init*)) KEEP(*(.initcall3s.init*))
  KEEP(*(.initcall4.init*)) KEEP(*(.initcall4s.init*))
  KEEP(*(.initcall5.init*)) KEEP(*(.initcall5s.init*))
  KEEP(*(.initcallrootfs.init*)) KEEP(*(.initcallrootfss.init*))
  KEEP(*(.initcall6.init*)) KEEP(*(.initcall6s.init*))
  KEEP(*(.initcall7.init*)) KEEP(*(.initcall7s.init*))
  *(.initcalls._end)
 }
}
