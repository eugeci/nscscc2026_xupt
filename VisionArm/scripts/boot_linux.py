#!/usr/bin/env python3
"""Program the VisionArm/NPU FPGA and boot Linux through PMON and TFTP."""

from __future__ import annotations

import argparse
import glob
import ipaddress
import os
import pwd
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import termios
import threading
import time
import tty
from pathlib import Path
from typing import Iterable, NoReturn, Optional, Pattern, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
VISIONARM_DIR = SCRIPT_DIR.parent
RELEASE_DIR = VISIONARM_DIR / "release"
DEFAULT_BIT = RELEASE_DIR / "visionarm_npu_soc_top.bit"
DEFAULT_KERNEL = RELEASE_DIR / "vmlinux_visionarm_xnpu"
DEFAULT_BOOTARGS = (
    "console=ttyS0,115200 rdinit=/sbin/init "
    "initcall_debug=1 loglevel=20 ignore_loglevel"
)
SERIAL_CANDIDATES = ("/dev/ttyUSB*", "/dev/ttyACM*")


def log(message: str) -> None:
    print(f"[boot-linux] {message}", flush=True)


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def original_user_command(command: list[str]) -> list[str]:
    """Run Vivado as the invoking desktop user when this script uses sudo."""
    sudo_user = os.environ.get("SUDO_USER")
    if os.geteuid() == 0 and sudo_user and sudo_user != "root":
        user_home = pwd.getpwnam(sudo_user).pw_dir
        return [
            "sudo", "-u", sudo_user, "env", f"HOME={user_home}", *command
        ]
    return command


def run(command: list[str], *, as_original_user: bool = False) -> None:
    shown = " ".join(command)
    log(f"执行：{shown}")
    actual = original_user_command(command) if as_original_user else command
    subprocess.run(actual, check=True)


def locate_vivado(explicit: Optional[str]) -> str:
    sudo_user = os.environ.get("SUDO_USER")
    search_home = (
        Path(pwd.getpwnam(sudo_user).pw_dir)
        if sudo_user and sudo_user != "root"
        else Path.home()
    )
    candidates = [explicit, os.environ.get("VIVADO_BIN"), shutil.which("vivado")]
    for pattern in (
        search_home / "Xilinx/Vivado/*/bin/vivado",
        Path("/opt/Xilinx/Vivado/*/bin/vivado"),
        Path("/tools/Xilinx/Vivado/*/bin/vivado"),
    ):
        candidates.extend(sorted(glob.glob(str(pattern)), reverse=True))
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    fail("找不到 Vivado；请用 --vivado 指定 Vivado 2023.2 可执行文件")


def detect_serial(explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    devices: list[str] = []
    for pattern in SERIAL_CANDIDATES:
        devices.extend(glob.glob(pattern))
    devices = sorted(set(devices))
    if len(devices) == 1:
        return devices[0]
    if not devices:
        fail("未发现 /dev/ttyUSB* 或 /dev/ttyACM*；请连接串口或使用 --serial")
    fail("发现多个串口设备，请使用 --serial 指定：" + ", ".join(devices))


def host_has_ip(host_ip: str, interface: Optional[str]) -> bool:
    command = ["ip", "-o", "-4", "addr", "show"]
    if interface:
        command.extend(["dev", interface])
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    return re.search(rf"\binet\s+{re.escape(host_ip)}/", result.stdout) is not None


def configure_network(interface: str, host_ip: str, prefix: int) -> None:
    if host_has_ip(host_ip, interface):
        log(f"主机网口 {interface} 已配置 {host_ip}/{prefix}")
        return
    commands = [
        ["ip", "link", "set", "dev", interface, "up"],
        ["ip", "addr", "replace", f"{host_ip}/{prefix}", "dev", interface],
    ]
    for command in commands:
        if os.geteuid() == 0:
            run(command)
        else:
            run(["sudo", *command])
    if not host_has_ip(host_ip, interface):
        fail(f"无法在 {interface} 上配置 {host_ip}/{prefix}")


class ReadOnlyTftpServer:
    """Minimal RFC 1350 read-only TFTP server for one kernel image."""

    def __init__(
        self, host: str, filename: str, source: Path, *, port: int = 69
    ) -> None:
        self.host = host
        self.port = port
        self.filename = filename.lstrip("/")
        self.source = source
        self.stop_event = threading.Event()
        self.ready_event = threading.Event()
        self.error: Optional[BaseException] = None
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.listen_socket: Optional[socket.socket] = None

    def start(self) -> None:
        self.thread.start()
        if not self.ready_event.wait(5):
            fail("TFTP 服务启动超时")
        if self.error:
            raise RuntimeError(f"TFTP 服务启动失败：{self.error}") from self.error

    def stop(self) -> None:
        self.stop_event.set()
        if self.listen_socket:
            self.listen_socket.close()
        self.thread.join(timeout=2)

    def _serve(self) -> None:
        try:
            listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((self.host, self.port))
            listener.settimeout(0.5)
            self.listen_socket = listener
            self.ready_event.set()
            log(f"TFTP 服务监听 {self.host}:{self.port}，文件名 /{self.filename}")
            while not self.stop_event.is_set():
                try:
                    request, address = listener.recvfrom(2048)
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(
                    target=self._handle_request,
                    args=(request, address),
                    daemon=True,
                ).start()
        except BaseException as exc:  # make startup failures visible to main
            self.error = exc
            self.ready_event.set()

    @staticmethod
    def _error_packet(code: int, message: str) -> bytes:
        return struct.pack("!HH", 5, code) + message.encode() + b"\0"

    def _handle_request(self, request: bytes, address: Tuple[str, int]) -> None:
        transfer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        transfer.settimeout(2.0)
        try:
            if len(request) < 4 or struct.unpack("!H", request[:2])[0] != 1:
                transfer.sendto(self._error_packet(4, "RRQ required"), address)
                return
            fields = request[2:].split(b"\0")
            requested = fields[0].decode("utf-8", "replace").lstrip("/")
            if requested != self.filename:
                transfer.sendto(self._error_packet(1, "File not found"), address)
                log(f"拒绝 TFTP 请求 /{requested}")
                return
            log(f"向 {address[0]} 发送 {self.source.name}")
            with self.source.open("rb") as image:
                block = 1
                sent = 0
                while not self.stop_event.is_set():
                    payload = image.read(512)
                    packet = struct.pack("!HH", 3, block & 0xFFFF) + payload
                    acknowledged = False
                    for _ in range(8):
                        transfer.sendto(packet, address)
                        try:
                            reply, peer = transfer.recvfrom(2048)
                        except socket.timeout:
                            continue
                        if peer == address and len(reply) >= 4:
                            opcode, ack_block = struct.unpack("!HH", reply[:4])
                            if opcode == 4 and ack_block == (block & 0xFFFF):
                                acknowledged = True
                                break
                    if not acknowledged:
                        log(f"TFTP block {block} 超时，终止传输")
                        return
                    sent += len(payload)
                    if len(payload) < 512:
                        log(f"TFTP 传输完成：{sent} bytes")
                        return
                    block += 1
        except OSError as exc:
            log(f"TFTP 传输失败：{exc}")
        finally:
            transfer.close()


class SerialConsole:
    def __init__(self, path: str, baud: int) -> None:
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] = 0
        attrs[1] = 0
        attrs[2] = termios.CS8 | termios.CLOCAL | termios.CREAD
        attrs[3] = 0
        attrs[4] = termios.B115200
        attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 1
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.buffer = bytearray()
        log(f"串口已打开：{path}，{baud} 8N1，无流控")

    def close(self) -> None:
        os.close(self.fd)

    def write(self, data: bytes) -> None:
        offset = 0
        while offset < len(data):
            _, writable, _ = select.select([], [self.fd], [], 2)
            if not writable:
                fail("串口写入超时")
            offset += os.write(self.fd, data[offset:])

    def command(self, command: str, prompt: Pattern[bytes], timeout: float) -> bytes:
        log(f"PMON> {command}")
        self.buffer.clear()
        self.write(command.encode() + b"\r")
        output = self.wait_for([(prompt, "PMON prompt")], timeout)[1]
        lowered = output.lower()
        if any(word in lowered for word in (
            b"exception",
            b"not found",
            b"timeout",
            b"invalid file format",
            b"attempt to load",
        )):
            fail(f"PMON 命令失败：{command}")
        return output

    def wait_for(
        self,
        patterns: Iterable[Tuple[Pattern[bytes], str]],
        timeout: float,
        *,
        nudge: bool = False,
    ) -> Tuple[str, bytes]:
        compiled = list(patterns)
        deadline = time.monotonic() + timeout
        next_nudge = time.monotonic() + 5
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.fd], [], [], 0.25)
            if readable:
                try:
                    chunk = os.read(self.fd, 4096)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    self.buffer.extend(chunk)
                    if len(self.buffer) > 256 * 1024:
                        del self.buffer[: len(self.buffer) - 128 * 1024]
                    snapshot = bytes(self.buffer)
                    for pattern, name in compiled:
                        if pattern.search(snapshot):
                            return name, snapshot
            if nudge and time.monotonic() >= next_nudge:
                self.write(b"\r")
                next_nudge = time.monotonic() + 5
        expected = ", ".join(name for _, name in compiled)
        fail(f"等待 {expected} 超时（{timeout:.0f}s）")

    def interactive(self) -> None:
        if not sys.stdin.isatty():
            log("标准输入不是终端，结束自动化流程")
            return
        log("进入 Linux 串口控制台；按 Ctrl-] 退出")
        stdin_fd = sys.stdin.fileno()
        old_attrs = termios.tcgetattr(stdin_fd)
        try:
            tty.setraw(stdin_fd)
            while True:
                readable, _, _ = select.select([stdin_fd, self.fd], [], [])
                if self.fd in readable:
                    try:
                        data = os.read(self.fd, 4096)
                    except BlockingIOError:
                        data = b""
                    if data:
                        os.write(sys.stdout.fileno(), data)
                if stdin_fd in readable:
                    data = os.read(stdin_fd, 1024)
                    if b"\x1d" in data:
                        return
                    if data:
                        self.write(data)
        finally:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_attrs)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="烧录 PMON 后，自动下载 FPGA 位流并通过 PMON/TFTP 启动 Linux。"
    )
    parser.add_argument("--serial", help="串口设备；仅发现一个设备时可省略")
    parser.add_argument("--baud", type=int, default=115200, choices=[115200])
    parser.add_argument("--interface", help="板卡直连的主机网卡，例如 enp3s0")
    parser.add_argument("--host-ip", default="192.168.1.100")
    parser.add_argument("--board-ip", default="192.168.1.101")
    parser.add_argument("--prefix", type=int, default=24)
    parser.add_argument("--bit", type=Path, default=DEFAULT_BIT)
    parser.add_argument("--kernel", type=Path, default=DEFAULT_KERNEL)
    parser.add_argument("--tftp-name", default="vmlinux_visionarm_xnpu")
    parser.add_argument(
        "--handoff-elf",
        type=Path,
        help="内核装载后再装载的可选 ELF 跳板；用于隔离 PMON 交接问题",
    )
    parser.add_argument(
        "--handoff-tftp-name",
        default="linux_handoff_trampoline",
        help="可选 ELF 跳板的 TFTP 文件名",
    )
    parser.add_argument("--bootargs", default=DEFAULT_BOOTARGS)
    parser.add_argument("--vivado", help="Vivado 可执行文件路径")
    parser.add_argument("--skip-program", action="store_true", help="不下载 bitstream")
    parser.add_argument(
        "--skip-network-config", action="store_true", help="不修改主机网卡配置"
    )
    parser.add_argument(
        "--external-tftp", action="store_true", help="使用已启动的外部 TFTP 服务"
    )
    parser.add_argument("--no-console", action="store_true", help="启动成功后退出")
    parser.add_argument("--check", action="store_true", help="仅检查文件、工具和参数")
    parser.add_argument("--pmon-timeout", type=float, default=120)
    parser.add_argument("--load-timeout", type=float, default=300)
    parser.add_argument("--boot-timeout", type=float, default=180)
    parser.add_argument(
        "--success-pattern",
        help="启动后以该正则表达式作为成功判据，适合 PMON 裸机 ELF",
    )
    return parser.parse_args()


def validate(
    args: argparse.Namespace,
) -> Tuple[Path, Path, Optional[Path], str, Optional[str]]:
    bit = args.bit.expanduser().resolve()
    kernel = args.kernel.expanduser().resolve()
    if not args.skip_program and not bit.is_file():
        fail(f"位流不存在：{bit}")
    if not kernel.is_file():
        fail(f"Linux 内核不存在：{kernel}")
    handoff = (
        args.handoff_elf.expanduser().resolve() if args.handoff_elf else None
    )
    if handoff is not None and not handoff.is_file():
        fail(f"ELF 跳板不存在：{handoff}")
    if "/" in args.tftp_name or not args.tftp_name:
        fail("--tftp-name 必须是单个文件名")
    if "/" in args.handoff_tftp_name or not args.handoff_tftp_name:
        fail("--handoff-tftp-name 必须是单个文件名")
    if handoff is not None and args.handoff_tftp_name == args.tftp_name:
        fail("内核与 ELF 跳板的 TFTP 文件名不能相同")
    try:
        ipaddress.IPv4Address(args.host_ip)
        ipaddress.IPv4Address(args.board_ip)
    except ipaddress.AddressValueError as exc:
        fail(f"IP 地址无效：{exc}")
    if args.host_ip == args.board_ip:
        fail("主机 IP 与板卡 IP 不能相同")
    if not 0 <= args.prefix <= 32:
        fail("--prefix 必须在 0 到 32 之间")
    if not args.skip_network_config and not args.interface:
        fail("自动配置网口时必须提供 --interface；或使用 --skip-network-config")
    if shutil.which("ip") is None:
        fail("找不到 ip 命令；请安装 iproute2")
    vivado = None if args.skip_program else locate_vivado(args.vivado)
    serial_path = args.serial if args.check else detect_serial(args.serial)
    return bit, kernel, handoff, serial_path or "(auto)", vivado


def main() -> int:
    args = parse_args()
    tftp: Optional[ReadOnlyTftpServer] = None
    serial: Optional[SerialConsole] = None
    try:
        bit, kernel, handoff, serial_path, vivado = validate(args)
        log(f"位流：{bit}")
        log(f"内核：{kernel}（TFTP /{args.tftp_name}）")
        if handoff is not None:
            log(f"交接跳板：{handoff}（TFTP /{args.handoff_tftp_name}）")
        log(f"网络：主机 {args.host_ip}/{args.prefix}，板卡 {args.board_ip}")
        log(f"串口：{serial_path}")
        if args.check:
            log("预检查通过")
            return 0

        if args.skip_network_config:
            if not host_has_ip(args.host_ip, args.interface):
                fail(f"主机尚未配置 {args.host_ip}；请配置后重试")
        else:
            configure_network(args.interface, args.host_ip, args.prefix)

        if not args.external_tftp:
            if os.geteuid() != 0:
                fail("内置 TFTP 需要绑定 UDP 69；请使用 sudo -E 运行或指定 --external-tftp")
            tftp = ReadOnlyTftpServer(args.host_ip, args.tftp_name, kernel)
            tftp.start()

        serial = SerialConsole(serial_path, args.baud)

        if not args.skip_program:
            assert vivado is not None
            run(
                [
                    vivado,
                    "-mode", "batch",
                    "-nolog", "-nojournal",
                    "-source", str(SCRIPT_DIR / "program_bitstream.tcl"),
                    "-tclargs", str(bit),
                ],
                as_original_user=True,
            )
        else:
            log("已跳过 bitstream 下载；请确保开发板正在运行目标设计")

        # Match only an idle prompt at the end of the received stream.  PMON
        # may echo an input line as "PMON> load ..."; accepting the "PMON>"
        # prefix of that echo makes the next command run while TFTP is active.
        pmon_prompt = re.compile(
            rb"(?:^|[\r\n])PMON[^\r\n>#]{0,24}[>#][ \t]*[\r\n]*\Z"
        )
        serial.buffer.clear()
        log("等待 PMON 提示符")
        serial.wait_for([(pmon_prompt, "PMON prompt")], args.pmon_timeout, nudge=True)

        serial.command(
            f"ifconfig dmfe0 {args.board_ip}", pmon_prompt, timeout=30
        )
        serial.command(
            f"load tftp://{args.host_ip}/{args.tftp_name}",
            pmon_prompt,
            timeout=args.load_timeout,
        )

        if handoff is not None:
            if not args.external_tftp:
                assert tftp is not None
                tftp.stop()
                tftp = ReadOnlyTftpServer(
                    args.host_ip, args.handoff_tftp_name, handoff
                )
                tftp.start()
            serial.command(
                f"load tftp://{args.host_ip}/{args.handoff_tftp_name}",
                pmon_prompt,
                timeout=args.load_timeout,
            )

        log(f"PMON> g {args.bootargs}")
        serial.buffer.clear()
        serial.write(f"g {args.bootargs}\r".encode())
        if args.success_pattern:
            try:
                success_pattern = re.compile(args.success_pattern.encode())
            except re.error as exc:
                fail(f"--success-pattern 正则表达式无效：{exc}")
            event, _ = serial.wait_for(
                [
                    (success_pattern, "requested success pattern"),
                    (re.compile(rb"Kernel panic", re.I), "kernel panic"),
                ],
                args.boot_timeout,
            )
        else:
            event, _ = serial.wait_for(
                [
                    (re.compile(rb"Please press Enter", re.I), "console activation"),
                    (re.compile(rb"(?:^|[\r\n])/ #\s*", re.M), "Linux shell"),
                    (re.compile(rb"Kernel panic", re.I), "kernel panic"),
                ],
                args.boot_timeout,
            )
        if event == "kernel panic":
            fail("Linux 启动过程中发生 Kernel panic")
        if event == "console activation":
            serial.buffer.clear()
            serial.write(b"\r")
            event, _ = serial.wait_for(
                [(re.compile(rb"(?:^|[\r\n])/ #\s*", re.M), "Linux shell")],
                30,
            )

        if args.success_pattern:
            log(f"目标程序成功，已匹配：{args.success_pattern}")
            return 0

        log("Linux 启动成功，已出现 / # 提示符")
        if not args.no_console:
            serial.interactive()
        return 0
    except (RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        print(f"[boot-linux] ERROR: {exc}", file=sys.stderr, flush=True)
        return 1
    finally:
        if serial:
            serial.close()
        if tftp:
            tftp.stop()


if __name__ == "__main__":
    raise SystemExit(main())
