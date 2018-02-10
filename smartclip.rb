# 
# What is this? Smartclip is a contextually-aware paperclip processor that crops and scales your images to maximize aesthetic quality.
# 
# The algorithm is fairly dumb:
#   - Find edges
#   - Find regions with a color like skin
#   - Find regions high in saturation
#   - Generate a set of thumbnail candidates
#   - Rank candidates using an importance function to focus the detail in the center and avoid it in the edges.
#   - The highest ranking candidate is selected and is processed by Paperclip
#
# While initially written with The Glass Files in mind, I've abstracted away all the hardcoded specifics so it should work generically.
# Images smaller than the desired thumbnail size are automatically padded with a border rather than being enlarged.
#
# The algorithm is fairly simple and is an adjusted a port of smartcrop.js by Jonas Wagner.
# Author: Elias Gabriel
# Active Repo: https://github.com/TheMasterGabriel/Smartclip
#
module Paperclip
	class Smartclip < Processor
		attr_accessor :geometry, :whiny, :auto_orient
		PROPERTIES = {
			resize_width: 210.0,
			resize_height: 210.0,
			backgroundColor: "#222222",
			doFileOptimization: true,
			cropWidth: 0.0,
			cropHeight: 0.0,
			detailWeight: 0.2,
			skinColor: [0.78, 0.57, 0.44],
			skinBias: 0.01,
			skinBrightnessMin: 0.2,
			skinBrightnessMax: 1.0,
			skinThreshold: 0.8,
			skinWeight: 1.8,
			saturationBrightnessMin: 0.05,
			saturationBrightnessMax: 0.9,
			saturationThreshold: 0.4,
			saturationBias: 0.2,
			saturationWeight: 0.1,
			scoreDownSample: 8.0,
			step: 8.0,
			scaleStep: 0.1,
			minScale: 1.0,
			maxScale: 1.0,
			edgeRadius: 0.4,
			edgeWeight: -20.0,
			outsideImportance: -0.5,
			boostWeight: 100.0
		}.freeze

		def initialize(file, options = {}, attachment = nil)
			super
			@whiny = options.fetch(:whiny, true)
			@current_format = File.extname(@file.path).downcase
			@basename = File.basename(@file.path, @current_format)
			@geometry = options.fetch(:file_geometry_parser, Geometry).from_file(@file)
			@properties = PROPERTIES.dup.merge(options)

			# Numberize all hash values to avoid problems (or cause them if something is not correct)?

			if @geometry.respond_to?(:auto_orient)
            	@geometry.auto_orient
            	@auto_orient = true
            end
		end

		def make
			@source = "#{File.expand_path(@file.path)}#{'[0]'}"  

			begin
				if @properties[:doFileOptimization]
					# Optimize image format based on image properties to reduce file size and increase load time (micro-optimization much?):
					#   - If it has no transparency make it a JPEG
					#   - In any other case, make it a PNG (we can ignore animation as this is a thumbnail)
					#
					# * Once WebP gets native integration for all modern browsers, this might change
					opaque = identify("-format #{%[%[opaque]]} :source", :source => @source)
					@current_format = (opaque == "True" ? '.jpg' : '.png')
				end

				@dst = TempfileFactory.new.generate([@basename, @current_format].join)
				@dest = File.expand_path(@dst.path)

				# Do all the crop calculations. Refer to the algorithm above for specifics
				#   - Pixel bytes are processed by ImageMagick so that I don't have to deal with encoding headers; a sacrifice of processing time for sanity.
				calculateDimensions
				bytes, * = convert(":source RGBA:-", :source => @dest)
				@pixels = bytes.unpack("C*")
				bytes.clear
				@opixels = Array.new(@geometry.width * @geometry.height * 4, 0)
				edgeDetect
				skinDetect
				saturationDetect
				crop = generateCrop(downSample)
				crop[:width] /= @prescale
				crop[:height] /= @prescale
				crop[:x] /= @prescale
				crop[:y] /= @prescale

				# Construct ImageMagick convert command. The order of the sub-commands is important, and are as follows:
				#   - Fix orientation
				#   - Optimize by interlacing, stripping non-functional data and, if the thumbnail is a JPEG, by color data manipulation (if enabled)
				#   - Crop to calculated offset
				#   - Resize to calculated scale
				#   - Add border if image is smaller than desired width or height
				parameters = []
				parameters << ":source"
				parameters << "-auto-orient" if @auto_orient
				parameters << "-crop #{crop[:width]}x#{crop[:height]}+#{crop[:x]}+#{crop[:y]} +repage"
				parameters << "-thumbnail" << %["#{@properties[:resize_width]}x#{@properties[:resize_height]}\>"]
				parameters << "-background" << %["#{@properties[:backgroundColor]}"]
				parameters << "-gravity center"
				parameters << "-extent #{@properties[:resize_width]}x#{@properties[:resize_height]}"

				if @properties[:doFileOptimization]
					parameters << "-sampling-factor 4:2:0 -colorspace RGB -quality 60" if @current_format == '.jpg'
					# parameters << "-depth 24 -define png:compression-filter=2 -define png:compression-level=9 -define png:compression-strategy=1" if @current_format == '.png'
					parameters << "-interlace PLANE -strip"
				end

	     	   	parameters << ":dest"
				parameters = parameters.flatten.compact.join(" ").strip.squeeze(" ")
				convert(parameters, :source => @source, :dest => @dest)
		    rescue Cocaine::ExitStatusError => e
        		raise Paperclip::Error, "There was an error processing the thumbnail for #{@basename}\nError: #{e}" if @whiny
      		rescue Cocaine::CommandNotFoundError => e
        		raise Paperclip::Errors::CommandNotFoundError.new("Could not run the `convert` command. Please install ImageMagick.")
			end
			  
			@dst
		end

		def target
    		@attachment.instance
    	end

		def calculateDimensions
			@scale = [@geometry.width / @properties[:resize_width], @geometry.height / @properties[:resize_height]].min
			@properties[:cropWidth] = (@properties[:resize_width] * @scale).floor
			@properties[:cropHeight] = (@properties[:resize_height] * @scale).floor
			@properties[:minScale] = [@properties[:maxScale], [1 / @scale, @properties[:minScale]].max].min
			@prescale = [[256 / @geometry.width, 256 / @geometry.height].max, 1].min

			if @prescale < 1
				convert(":source #{"-auto-orient " if @auto_orient}-resize #{(@geometry.width * @prescale).floor}x#{(@geometry.height * @prescale).floor} :dest", :source => @source, :dest => @dest)
				@geometry = options.fetch(:file_geometry_parser, Geometry).from_file(@dst)
				@properties[:cropWidth] = (@properties[:cropWidth] * @prescale).floor
				@properties[:cropHeight] = (@properties[:cropHeight] * @prescale).floor
			else
				convert(":source #{"-auto-orient " if @auto_orient}:dest", :source => @source, :dest => @dest)
				@geometry = options.fetch(:file_geometry_parser, Geometry).from_file(@dst)
				@prescale = 1;
			end
        end

		def edgeDetect
			w = @geometry.width
			h = @geometry.height

			for y in 0..(h - 1)
				for x in 0..(w - 1)
					p = (y * w + x) * 4
					lightness = 0

					if x == 0 || x >= w - 1 || y == 0 || y >= h - 1
						lightness = sample(p)
					else
						lightness = sample(p) * 4 - sample(p - w * 4) - sample(p - 4) - sample(p + 4) - sample(p + w * 4)
					end

					@opixels[p + 1] = lightness
				end
			end
		end

		def sample(p)
			cie(@pixels[p], @pixels[p + 1], @pixels[p + 2])
		end

		def skinDetect
			w = @geometry.width
			h = @geometry.height

			for y in 0..(h - 1)
				for x in 0..(w - 1)
					p = (y * w + x) * 4
					lightness = cie(@pixels[p], @pixels[p + 1], @pixels[p + 2]) / 255
					skin = skinColor(@pixels[p], @pixels[p + 1], @pixels[p + 2])

					if skin > @properties[:skinThreshold] && lightness >= @properties[:skinBrightnessMin] && lightness <= @properties[:skinBrightnessMax]
						@opixels[p] = (skin - @properties[:skinThreshold]) * (255 / (1 / @properties[:skinThreshold]))
					else
						@opixels[p] = 0
					end
				end
			end
		end

		def skinColor(r, g, b)
			mag = Math.sqrt(r * r + g * g + b * b)
			rd = (r / mag - @properties[:skinColor][0])
			gd = (g / mag - @properties[:skinColor][1])
			bd = (b / mag - @properties[:skinColor][2])
			d = Math.sqrt(rd * rd + gd * gd + bd * bd)
			1 - d
		end

		def saturationDetect
			w = @geometry.width
			h = @geometry.height

			for y in 0..(h - 1)
				for x in 0..(w - 1)
					p = (y * w + x) * 4
					lightness = cie(@pixels[p], @pixels[p + 1], @pixels[p + 2]) / 255
					sat = saturation(@pixels[p], @pixels[p + 1], @pixels[p + 2])
					
					if sat > @properties[:saturationThreshold] && lightness >= @properties[:saturationBrightnessMin] && lightness <= @properties[:saturationBrightnessMax]
						@opixels[p + 2] = (sat - @properties[:saturationThreshold]) * (255 / (1 - @properties[:saturationThreshold]))
					else
						@opixels[p + 2] = 0
					end
				end
			end
		end

		def saturation(r, g, b)
			rgb = [r / 255, g / 255, b / 255]
			max = rgb.max
			min = rgb.min

			if max == min
				0
			else
				l = (max + min) / 2
				d = max - min
				l > 0.5 ? d / (2 - max - min) : d / (max + min)
			end
		end

		def cie(r, g, b)
			0.0722 * r + 0.7152 * g + 0.5126 * b
		end

		def downSample
			factor = @properties[:scoreDownSample]
			iwidth = @geometry.width
			width = (iwidth / factor).floor
			height = (@geometry.height / factor).floor
			ifactor2 = 1 / (factor * factor)
			data = []

			for y in 0..(height - 1)
				for x in 0..(width - 1)
					i = (y * width + x) * 4
					r = 0
					g = 0
					b = 0
					a = 0
					mr = 0
					mg = 0
					mb = 0

					for v in 0..(factor - 1)
						for u in 0..(factor - 1)
							j = ((y * factor + v) * iwidth + (x * factor + u)) * 4
							r += @opixels[j]
							g += @opixels[j + 1]
							b += @opixels[j + 2]
							a += @opixels[j + 3]
							mr = [mr, @opixels[j]].max
							mg = [mg, @opixels[j + 1]].max
							# mb = [mb, @opixels[j + 2]].max
						end
					end

					data[i] = r * ifactor2 * 0.5 + mr * 0.5
					data[i + 1] = g * ifactor2 * 0.7 + mg * 0.3
					data[i + 2] = b * ifactor2
					data[i + 3] = a * ifactor2
				end
			end

			data
		end

		def generateCrop(scoreOutput)
			cropWidth = @properties[:cropWidth]
			cropHeight = @properties[:cropHeight]
			scale = @properties[:maxScale]
			y = 0
			x = 0
			topScore = -1.0 / 0
			topCrop = nil

			while scale >= @properties[:minScale]
				while y + cropHeight * scale <= @geometry.height
					while x + cropWidth * scale <= @geometry.width
						crop = {
							x: x,
							y: y,
							width: cropWidth * scale,
							height: cropHeight * scale
						}
						crop[:score] = score(scoreOutput, crop)

						if crop[:score][:total] > topScore
							topCrop = crop
							topScore = crop[:score][:total]
						end

						x += @properties[:step]
					end

					y += @properties[:step]
				end

				scale -= @properties[:scaleStep]
			end

			topCrop
		end

		def score(output, crop)
			result = {
				detail: 0,
				saturation: 0,
				skin: 0,
				boost: 0,
				total: 0
			}
			width = @geometry.width
			downSample = @properties[:scoreDownSample]
			invDownSample = 1 / downSample
			outputHeightDownSample = @geometry.height * downSample
			outputWidthDownSample = width * downSample
			y = 0
			x = 0

			while y < outputHeightDownSample
				while x < outputWidthDownSample
					p = ((y * invDownSample).floor * width + (x * invDownSample).floor) * 4
					i = importance(crop, x, y)
					detail = output[p + 1] / 255

					result[:skin] += output[p] / 255 * (detail + @properties[:skinBias]) * i
					result[:detail] += detail * i
					result[:saturation] += output[p + 2] / 255 * (detail + @properties[:saturationBias])
					result[:boost] += output[p + 3] / 255 * i

					x += downSample
				end

				y += downSample
			end

			result[:total] = (result[:detail] * @properties[:detailWeight] + result[:skin] * @properties[:skinWeight] + result[:saturation] * @properties[:saturationWeight] + result[:boost] * @properties[:boostWeight]) / (crop[:width] * crop[:height])
			result
		end

		def importance(crop, x, y)
			if crop[:x] > x || x >= crop[:x] + crop[:width] || crop[:y] > y || y >= crop[:y] + crop[:height]
				@properties[:outsideImportance]
			else
				x = (x - crop[:x]) / crop[:width]
				y = (y - crop[:y]) / crop[:height]
				px = (0.5 - x).abs * 2
				py = (0.5 - y).abs * 2
				dx = [px - 1.0 + @properties[:edgeRadius], 0].max
				dy = [py - 1.0 + @properties[:edgeRadius], 0].max
				d = (dx * dx + dy * dy) * @properties[:edgeWeight]
				s = 1.4142135623730951 - Math.sqrt(px * px + py * py)
				s += ([0, s + d + 0.5].max * 1.2) * (thirds(px) + thirds(py))
				s + d
			end
		end

		def thirds(x)
			x = ((x - (1 / 3) + 1.0) % 2.0 * 0.5 - 0.5) * 16
			[1.0 - x * x, 0].max
		end
	end
end