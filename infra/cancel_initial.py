"""Archive a verified empty initial preparation before using a corrected artifact.

Never use after fencing, role/network preparation or public commit. The original
journal is preserved verbatim; no user data, secret, service or pointer is changed.
"""
import argparse
import json
import os
from pathlib import Path
import platform

from initial_cohost import cancel_preparation


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--attempt',required=True)
    args=parser.parse_args()
    if platform.system()!='Linux' or os.geteuid()!=0:raise SystemExit('Selected Linux host as root required')
    print(json.dumps(cancel_preparation(args.root,args.attempt)))


if __name__=='__main__':main()
