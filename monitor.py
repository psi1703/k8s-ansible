# OTP Relay Monitor compatibility entrypoint.
# Runtime logic lives in otp_monitor/ so future changes are small and focused.

from otp_monitor.runner import main


if __name__ == "__main__":
    main()
