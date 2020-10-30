import os
import subprocess
import socket
import tempfile
from contextlib import closing
from subprocess import TimeoutExpired
import argparse
import uuid

FIX_SSH_PERMISSION = """
mkdir -p /run/sshd
chown root ~/.ssh
chmod 700 ~/.ssh
chown root ~/.ssh/*
chmod 600 ~/.ssh/*
chmod 400 ~/.ssh/id_rsa
chmod 400 ~/.ssh/id_rsa.pub
chmod 600 ~/.ssh/config
"""


def find_free_port():
    with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        s.bind(("localhost", 0))
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return s.getsockname()[1]


def make_dotssh(dotssh_dir):
    bash_cmd = f"""set -ex
rm -rf /root/.ssh
ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys && \
    chmod 600 /root/.ssh/authorized_keys
/etc/init.d/ssh start && \
    ssh-keyscan -H localhost >> /root/.ssh/known_hosts

cp -r /root/.ssh/* {dotssh_dir}
chmod 777 {dotssh_dir}
chmod 777 {dotssh_dir}/*
"""
    with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as f:
        f_name = f.name
        f.write(bash_cmd)
        f.flush()
        subprocess.check_call(
            f"docker run -v /tmp:/host/tmp -v {dotssh_dir}:{dotssh_dir} -w $PWD oneflow-test:$USER bash /host/{f_name}",
            shell=True,
        )
    config_content = """Host *
	StrictHostKeyChecking no
"""
    with open(os.path.join(dotssh_dir, "config"), "w") as f:
        f.write(config_content)


def launch_remote_container(hostname, docker_ssh_port, survival_time, dotssh_dir):
    workspace_name = "distributed_run_workspace"
    subprocess.check_call(
        f"ssh {hostname} docker run --rm -v $HOME:$HOME -w $HOME busybox rm -rf {workspace_name}",
        shell=True,
    )
    subprocess.check_call(f"ssh {hostname} mkdir ~/{workspace_name}/", shell=True)
    subprocess.check_call(
        f"scp -r {dotssh_dir} {hostname}:~/{workspace_name}/dotssh", shell=True
    )
    bash_cmd = f"""set -ex
{FIX_SSH_PERMISSION}
/usr/sbin/sshd -p {docker_ssh_port}
sleep {survival_time}
"""
    with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as f:
        f_name = f.name
        f.write(bash_cmd)
        f.flush()
        subprocess.check_call(
            f"scp {f_name} {hostname}:~/{workspace_name}/launch_ssh_server.sh",
            shell=True,
        )
        home_dir = os.path.expanduser("~")
    docker_cmd = f"""docker run --privileged --network=host --shm-size=8g --rm -v {home_dir}/{workspace_name}/dotssh:/root/.ssh -v {home_dir}/{workspace_name}:/{workspace_name} -w /{workspace_name} -v /dataset:/dataset -v /model_zoo:/model_zoo oneflow-test:$USER bash launch_ssh_server.sh
"""
    ssh_cmd = f"ssh {hostname} {docker_cmd}"
    print(ssh_cmd)
    proc = subprocess.Popen(ssh_cmd, shell=True,)
    try:
        proc.wait(timeout=15)
        raise ValueError("sshd quit early, returncode:", proc.returncode)
    except TimeoutExpired:
        survival_time_min = survival_time / 60
        survival_time_min = int(survival_time_min)
        print(
            f"remote container launched, host: {hostname}, ssh port:{docker_ssh_port}, .ssh dir: {dotssh_dir}, survival: {survival_time_min} mins"
        )


def run_bash_script(bash_script, timeout, ssh_port, dotssh_dir, remote_host):
    assert os.path.exists(bash_script)
    log_dir = "./unittest-log-" + str(uuid.uuid4())
    ctrl_port = find_free_port()
    this_host = os.getenv("HOSTNAME")
    bash_cmd = f"""set -ex
export ONEFLOW_TEST_CTRL_PORT={ctrl_port}
export ONEFLOW_TEST_SSH_PORT={ssh_port}
export ONEFLOW_TEST_LOG_DIR={log_dir}
export ONEFLOW_TEST_NODE_LIST="{this_host},{remote_host}"
rm -rf ~/.ssh
cp -r /dotssh ~/.ssh
{FIX_SSH_PERMISSION}
bash {bash_script}
"""
    with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as f:
        f_name = f.name
        f.write(bash_cmd)
        f.flush()
        docker_cmd = f"docker run --privileged --network=host --shm-size=8g --rm -v /tmp:/host/tmp -v $PWD:$PWD -w $PWD -v {dotssh_dir}:/dotssh -v /dataset:/dataset -v /model_zoo:/model_zoo oneflow-test:$USER bash /host{f_name}"
        print(docker_cmd)
        subprocess.check_call(docker_cmd, shell=True, timeout=timeout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--launch_remote_container", action="store_true", required=False, default=False
    )
    parser.add_argument(
        "--make_dotssh", action="store_true", required=False, default=False
    )
    parser.add_argument("--run", action="store_true", required=False, default=False)
    parser.add_argument("--bash_script", type=str, required=False)
    parser.add_argument("--remote_host", type=str, required=False, default="oneflow-15")
    default_dotssh_dir = os.path.expanduser("~/distributed_run_dotssh")
    parser.add_argument(
        "--dotssh_dir", type=str, required=False, default=default_dotssh_dir
    )
    parser.add_argument("--ssh_port", type=int, required=False, default=None)
    parser.add_argument("--timeout", type=int, required=False, default=10 * 60)
    args = parser.parse_args()

    ssh_port = None
    if args.ssh_port:
        ssh_port = args.ssh_port
    else:
        ssh_port = find_free_port()
    assert ssh_port
    if args.make_dotssh:
        make_dotssh(args.dotssh_dir)

    if args.launch_remote_container:
        launch_remote_container(
            args.remote_host, ssh_port, args.timeout, args.dotssh_dir
        )

    if args.run:
        assert args.bash_script
        run_bash_script(
            args.bash_script, args.timeout, ssh_port, args.dotssh_dir, args.remote_host
        )
        exit(0)
