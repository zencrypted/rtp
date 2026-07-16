defmodule RtpTest do
  use ExUnit.Case, async: false

  setup_all do
    # Start Mnesia and the RTP application if they aren't started
    Application.ensure_all_started(:rtp)
    on_exit(fn ->
      # Clean up files created during the test
      for i <- 1..4 do
        File.rm_rf("priv/static/rooms/room_#{i}")
      end
    end)
    :ok
  end

  test "simulates 4 rooms and records video using K6" do
    # Run the K6 test script
    IO.puts("Running K6 simulation...")
    {output, exit_code} = System.cmd("k6", ["run", "test/k6_sim.js"])
    IO.puts(output)

    assert exit_code == 0, "K6 test failed"

    # Wait dynamically for ports to flush and close files (up to 15 seconds)
    for i <- 1..4 do
      filename = "priv/static/rooms/room_#{i}/index.m3u8"
      
      wait_for_file = fn loop, retries ->
        if File.exists?(filename) do
          stat = File.stat!(filename)
          if stat.size > 0 do
            IO.puts("Verified: #{filename} successfully recorded (#{stat.size} bytes)")
            :ok
          else
            if retries > 0 do
              Process.sleep(500)
              loop.(loop, retries - 1)
            else
              flunk("Recording file #{filename} is empty")
            end
          end
        else
          if retries > 0 do
            Process.sleep(500)
            loop.(loop, retries - 1)
          else
            flunk("Recording file #{filename} was not created")
          end
        end
      end
      
      wait_for_file.(wait_for_file, 30) # 30 * 500ms = 15 seconds
    end
  end
end
