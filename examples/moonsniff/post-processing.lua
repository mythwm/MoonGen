--- Demonstrates the basic usage of moonsniff in order to determine device induced latencies

local lm        = require "libmoon"
local device    = require "device"
local memory    = require "memory"
local ts        = require "timestamping"
local hist      = require "histogram"
local timer     = require "timer"
local log       = require "log"
local stats     = require "stats"
local barrier   = require "barrier"
local ms	= require "moonsniff-io"
local bit	= require "bit"

local ffi    = require "ffi"
local C = ffi.C

-- default values when no cli options are specified
local INPUT_PATH = "latencies.csv"
local INPUT_MODE = C.ms_text
local BITMASK = 0x00FFFFFF

function configure(parser)
        parser:description("Demonstrate and test hardware latency induced by a device under test.\nThe ideal test setup is to use 2 taps, one should be connected to the ingress cable, the other one to the egress one.\n\n For more detailed information on possible setups and usage of this script have a look at moonsniff.md.")
	parser:option("-i --input", "Path to input file.")
	parser:option("-s --second-input", "Path to second input file."):target("second")
	parser:flag("-b --binary", "Read a file which was generated by moonsniff with the binary flag set")
        return parser:parse()
end

function master(args)
	if args.input then INPUT_PATH = args.input end
	if args.binary then INPUT_MODE = C.ms_binary end

	if string.match(args.input, ".*%.mscap") then
		local PRE
		local POST

		if not args.second then log:fatal("Detected .mscap file but there was no second file. Single .mscap files cannot be processed.") end

		if string.match(args.input, ".*%-pre%.mscap") and string.match(args.second, ".*%-post%.mscap") then
			PRE = args.input
			POST = args.second
		

		elseif string.match(args.second, ".*%-pre%.mscap") and string.match(args.input, ".*%-post%.mscap") then
			POST = args.input
			PRE = args.second
		else
			log:fatal("Could not decide which file is pre and which post. Pre should end with -pre.mscap and post with -post.mscap.")
		end

		ffi.cdef[[
			void* malloc(size_t);
			void free(void*);
		]]

		local uint64_t = ffi.typeof("uint64_t")
		local uint64_p = ffi.typeof("uint64_t*")

		local map = C.malloc(ffi.sizeof(uint64_t) * BITMASK)
		map = ffi.cast(uint64_p, map)
		
		C.hs_initialize()
		local prereader = ms:newReader(args.input)
		local postreader = ms:newReader(args.second)

		local premscap = prereader:readSingle()
		local postmscap = postreader:readSingle()

		-- precache used bit operation
		local band = bit.band

		log:info("Entering loop")
		while premscap and postmscap do
			map[band(premscap.identification, BITMASK)] = premscap.timestamp
			premscap = prereader:readSingle()
			
			local ts = map[band(postmscap.identification, BITMASK)]
			if ts then C.hs_update(postmscap.timestamp - ts) end
			postmscap = postreader:readSingle()
		end

		while postmscap do
			local ts = map[band(postmscap.identification, BITMASK)]
			if ts then C.hs_update(postmscap.timestamp - ts) end
			postmscap = postreader:readSingle()
		end

		log:info("before closing")

		prereader:close()
		postreader:close()
		C.free(map)

		C.hs_finalize()

		log:info("Mean: " .. C.hs_getMean() .. ", Variance: " .. C.hs_getVariance() .. "\n")

		log:info("Finished processing. Writing histogram ...")
		C.hs_write("new_hist.csv")
		C.hs_destroy()

	else
        	printStats()
	end
end

function printStats()
        print()

	
        stats = C.ms_post_process(INPUT_PATH, INPUT_MODE)
        hits = stats.hits
        misses = stats.misses
        cold = stats.cold_misses
        invalidTS = stats.inval_ts
        print("Received: " .. hits + misses)
        print("\tHits: " .. hits)
        print("\tHits with invalid timestamps: " .. invalidTS)
        print("\tMisses: " .. misses)
        print("\tCold Misses: " .. cold)
        print("\tLoss by misses: " .. (misses/(misses + hits)) * 100 .. "%")
        print("\tTotal loss: " .. ((misses + invalidTS)/(misses + hits)) * 100 .. "%")
        print("Average Latency: " .. tostring(tonumber(stats.average_latency)/10^6) .. " ms")

end