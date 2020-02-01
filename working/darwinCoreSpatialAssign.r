#' Spatial designation of DawrinCore data (ie, GBIF)
#'
#' This function assigns a designation to each record obtained from GBIF (or at least a file in DarwinCore format) based on data in the data frame and comparison to a spatial object representing geography over which the records are assumed to have been collected (the default is to assume the spatial object was obtained from GADM). Each record is assigned a category indicating the kind of spatial uncertainty to use:
#' \itemize{
#' 	\item "precise": The record represents a point occurrence with negligible uncertainty.
#'  \item "imprecise": The record is best represented by a circular polygon around a point.
#'  \item "county": The record is best represented by a polygon outline of county, parish, or similar "second-level" administrative unit.
#'  \item "state": The record is best represented by a polygon outline of a state or province.
#'  \item "unusable": The record cannot be assigned to a unique state/county, has a coordinate uncertainty larger than allowed, has insufficient geolocation information, or otherwise cannot be located with reasonable certainty.
#' }
#' @param darwin Data frame in DarwinCore format. The data frame must contain at least these fields, although they can contain \code{NA}: \code{stateProvince}, \code{county}, \code{decimalLatitude}, \code{decimalLongitude}, and \code{coordinateUncertaintyInMeters}. The function does strict matching of names (but ignores capitalization), so misspellings, diacritics, trailing or leading spaces, etc. can lead to a mismatch between a field in this dtaa frame and the spatial object.
#' @param geogCounty SpatialPolygonsDataFrame representing the area over which the records in \code{darwin} were assumed to have been collected with the finest level representing "counties" (parishes or similar "secondary-level" administrative units). The data frame component must contain fields named in \code{stateField} and \code{countyGeogField}.
#' @param geogState SpatialPolygonsDataFrame representing the area over which the records in \code{darwin} were assumed to have been collected with the finest level representing "states" or "provinces" ("primary-level" administrative units). The data frame component must contain fields named in \code{stateField}.
#' @param eaProj PROJ4 string for an equal-area representation of the spatial polygons in \code{geogCounty} and \code{geogState}. This will look something like \code{'+proj=aea +lat_1=29.5 +lat_2=45.5 +lat_0=37.5 +lon_0=-96 +x_0=0 +y_0=0 +ellps=GRS80 +datum=NAD83 +units=m +no_defs'} (which is Albers Equal-Area for North America).
#' @param minCoordUncerForPrecise_m Integer, minimum value of coordinate uncertainty (in meters) required for a record to be designated "precise" (assuming other checks are OK).
#' @param maxPrecisionUncerForceCounty_m Numeric, a value representing meters.  Coordinates can be rounded or represent whole numbers divided by whole numbers.  As a result, they typically carry an imprecision that can be inferred from the number of digits after a decimal place and/or repetition of sequences after a decimal place. For example, the coordinate pair (-97.5, 37.2) could presumably be located anywhere within the bouncing box (-97.45 to -97.55 and 37.15 to 37.25).  The degree of this uncertainty can be calculated.  This argument causes records that have a given level of coordinate imprecision or more to be assigned to the county level if the area of the county is larger than teh area defined by teh coordinate uncertainty plus coordinate imprecision. For information on how number of significant decimal places is inferred, see\code{\link[omnibus]{roundedFrom}}. At the equator values rounded to 0 digits are accurate to within ~111 km, 1 digit ~11 km, and 2 digits ~1 km.  At latitudes of 45 north or south 0 digits is accurate to ~79 km, 1 digits to ~8 km, and 2 digits to ~0.8 km. The default is 100 meters.
#' @param maxPrecisionUncerForceState_m Same as \code{maxPrecisionUncerForceCounty_m} but teh record is forced to be a state-level record unless the area obtained using its coordinate uncertainty plus coordinate uimprecision uncertainty is larger. This value must be greater than \code{maxPrecisionUncerForceCounty_m}.  The default is 500 meters.
#' @param maxArea_km2 Numeric, maximum area (in km2) for an imprecise, county, or state/province record to be designated as "usable". Default is Inf.
#' @param countyGeogField Name of field (column) in \code{geog} with county names.
#' @param stateGeogField Name of field (column) in \code{geogCounty} and \code{geogState} with state/province names.
#' @param verbose Logical, if \code{TRUE} then display progress.
#' @param ... Other arguments, ignored for now.
#' @return A data frame with these fields:
#' \itemize{
#'		\item	\code{usable}: Logical, if \code{TRUE} then the record is classified as usable using methoids appropriate to the spatial uncertaity type assigned to it (next field).
#' 		\item	\code{uncerType}: "precise", "imprecise", "county", "state", or \code{NA}.
#' }
#' @details 
#' @seealso 
#' @examples
#' @export

darwinCoreSpatialAssign <- function(
	darwin,
	geogCounty,
	geogState,
	eaProj,
	minCoordUncerForPrecise_m,
	maxPrecisionUncerForceCounty_m = 100,
	maxPrecisionUncerForceState_m = 500,
	countyGeogField = 'NAME_2',
	stateGeogField = 'NAME_1',
	verbose = TRUE,
	...
) {

	if (verbose) omnibus::say('Pre-processing...')

	### NOTES
	#########
	
		# "augmented" values reflect accounting for rounding in coordinates (ie, adding distance to given coordinate uncertainty because the coordinates are rounded to a given level)

	### constants
	#############
		
		ll <- c('decimalLongitude', 'decimalLatitude')
		numRecords <- nrow(darwin)
		
		eaProj <- sp::CRS(eaProj)
		unprojProj <- sp::CRS(raster::projection(geogCounty))
		
	### output
	##########
		
		out <- data.frame(
			uncerType = rep(NA, numRecords),				# precise, imprecise, county, state
			stateInGeog = rep(NA, numRecords),				# TRUE/FALSE
			countyInGeog = rep(NA, numRecords),				# TRUE/FALSE
			stateCountyMatches = rep(NA, numRecords),		# TRUE/FALSE/NA
			stateFromGeog = rep(NA, numRecords),			# character/NA
			countyFromGeog = rep(NA, numRecords),			# character/NA
			stateFromCoords = rep(NA, numRecords),			# character/NA
			countyFromCoords = rep(NA, numRecords),			# character/NA
			coordPrecision_digits = rep(NA, numRecords),			# TRUE/FALSE/NA
			coordPrecision_m = rep(NA, numRecords),			# TRUE/FALSE/NA
			coordUncerArea_km2 = rep(NA, numRecords),		# positive numeric/NA
			coordUncerBasedOn = rep(NA, numRecords),		# caharcter/NA
			areaOfState_km2 = rep(NA, numRecords),			# numeric/NA (to drop)
			areaOfCounty_km2 = rep(NA, numRecords),			# numeric/NA (to drop)
			coordUncerAreaUsingCoords_km2 = rep(NA, numRecords)	# numeric/NA (to drop)
		)
		
		row.names(out) <- row.names(darwin)

	### simplify input
	##################
		
		darwin <- darwin[ , c('stateProvince', 'county', ll, 'coordinateUncertaintyInMeters', 'hasGeospatialIssues')]
		geogState@data <- geogState@data[ , which(names(geogState@data) %in% stateGeogField), drop=FALSE]
		geogCounty@data <- geogCounty@data[ , c(which(names(geogCounty@data) %in% stateGeogField), which(names(geogCounty@data) %in% countyGeogField)), drop=FALSE]

	### coordinates rounded?
	########################

		# number of decimal digits of coordinates (if NA then returns NA)
		numCoordDigitsLong <- omnibus::roundedFrom(darwin[ , ll[1]])
		numCoordDigitsLat <- omnibus::roundedFrom(darwin[ , ll[2]])
		
		numCoordDigitsLong <- -1 * numCoordDigitsLong
		numCoordDigitsLat <- -1 * numCoordDigitsLat
		
		numCoordDigits <- pmax(numCoordDigitsLong, numCoordDigitsLat)
		if (any(!is.na(numCoordDigits)) && any(numCoordDigits < 0)) numCoordDigits[!is.na(numCoordDigits) & numCoordDigits < 0] <- 0
		
		out$coordPrecision_digits <- numCoordDigits
		
		### calculate precision error
		recs <- which(complete.cases(darwin[ , c(ll)]))
		if (length(recs) > 0) {
			
			these <- darwin[complete.cases(darwin[ , c(ll)]), ]
			
			theseCoordDigits <- numCoordDigits[recs]
			these$decimalLongitude <- trunc(these$decimalLongitude * 10^theseCoordDigits) / 10^theseCoordDigits
			these$decimalLatitude <- trunc(these$decimalLatitude * 10^theseCoordDigits) / 10^theseCoordDigits

			theseSp <- sp::SpatialPoints(these[ , ll], proj4string=unprojProj)
			out$coordPrecision_m[recs] <- coordPrecision(theseSp)
		
		}
		
	### state/county names
	######################
		
		geogStateNamesFromStateGeog <- geogState@data[ , stateGeogField, drop=TRUE]
		geogStateNamesFromCountyGeog <- geogCounty@data[ , stateGeogField, drop=TRUE]
		countyNames <- geogCounty@data[ , countyGeogField, drop=TRUE]
		geogStateCountyNames <- tolower(paste(geogStateNamesFromCountyGeog, countyNames, sep=' '))

	### state in records also occurs in spatial data
	################################################
	
		out$stateInGeog <- tolower(darwin$stateProvince) %in% tolower(geogStateNamesFromStateGeog)

	### state/county in records matches spatial data
	################################################

		for (thisState in geogStateNamesFromStateGeog) {
		
			recs <- which(tolower(darwin$stateProvince) == tolower(thisState))

			if (length(recs) > 0) {
				
				thisStateCounties <- geogCounty@data[geogCounty@data[ , stateGeogField, drop=TRUE] == thisState, countyGeogField, drop=TRUE]
				thisStateCounties <- tolower(thisStateCounties)
				theseCounties <- tolower(darwin$county[recs])
				countiesInThisState <- theseCounties %in% thisStateCounties
			
				out$stateCountyMatches[recs] <- countiesInThisState
				
			}
		
		}

		### extract state/province and county from geography
	
		# extract for records with coordinates
		recs <- which(!is.na(darwin$decimalLongitude) & !is.na(darwin$decimalLatitude))
		
		if (length(recs) > 0) {
		
			these <- darwin[recs, ]
			ext <- raster::extract(geogCounty, these[ , ll])
			out$stateFromGeog[recs] <- ext[ , stateGeogField, drop=TRUE]
			out$countyFromGeog[recs] <- ext[ , countyGeogField, drop=TRUE]
		
		}
!!!
		# does state/county from records with coordinates match state/county extracted from geography?
		recs <- which(!is.na(darwin$decimalLongitude) & !is.na(darwin$decimalLatitude) & !is.na(darwin$stateProvince) & !is.na()
		
		if (length(recs) > 0) {
		
			these <- darwin[recs, ]
			ext <- raster::extract(geogCounty, these[ , ll])
			out$stateFromGeog[recs] <- ext[ , stateGeogField, drop=TRUE]
			out$countyFromGeog[recs] <- ext[ , countyGeogField, drop=TRUE]
		
		}

	### areas of adminstrative units
	################################

		geogStateEa <- sp::spTransform(geogState, eaProj)
		geogCountyEa <- sp::spTransform(geogCounty, eaProj)
		
		areaState_km2 <- rgeos::gArea(geogStateEa, byid=TRUE) / 1000^2
		areaCounty_km2 <- rgeos::gArea(geogCountyEa, byid=TRUE) / 1000^2

		names(areaState_km2) <- tolower(geogStateNamesFromStateGeog)
		names(areaCounty_km2) <- tolower(geogStateCountyNames)
		
		darwinStateNames <- tolower(darwin$stateProvince)
		darwinCountyNames <- tolower(darwin$county)
		darwinStateCountyNames <- paste(darwinStateNames, darwinCountyNames, sep=' ')
		
		out$areaOfState_km2 <- areaState_km2[match(darwinStateNames, names(areaState_km2))]
		out$areaOfCounty_km2 <- areaCounty_km2[match(darwinStateCountyNames, names(areaCounty_km2))]
		
	### areas of uncertainty
	########################
	
		recs <- which(!is.na(darwin$decimalLongitude) & !is.na(darwin$decimalLatitude) & omnibus::naCompare('<=', darwin$coordinateUncertaintyInMeters, 5000))
		
		if (length(recs) > 0) {
		
			these <- darwin[recs, ]

			coordPrecis_m <- coordPrecision(these[ , ll])
			coordPrecis_m <- coordPrecis_m * out$coordsRounded[recs]

			coordUncerAugmented_m <- these$coordinateUncertaintyInMeters + coordPrecis_m
			
			theseSp <- sp::SpatialPointsDataFrame(these[ , ll], data=these, proj4=unprojProj)
			theseSpEa <- sp::spTransform(theseSp, eaProj)
			theseSpEaBuffs <- rgeos::gBuffer(theseSpEa, byid=TRUE, width=coordUncerAugmented_m)
			
			out$coordUncerAreaUsingCoords_km2[recs] <- rgeos::gArea(theseSpEaBuffs, byid=TRUE) / 1000^2
			out$coordUncerAugmented_m[recs] <- coordUncerAugmented_m
			out$uncerFromRounding_m <- coordPrecis_m
		
		}

	### CLASSIFY RECORDS!!! ###
	###########################

		### YES state YES county YES coords YES CU (all, precise)
		#########################################################

			recs <- which(
				out$stateCountyMatches &
				!is.na(darwin$decimalLongitude) & !is.na(darwin$decimalLatitude) &
				naCompare('<=', out$coordUncerAugmented_m, minCoordUncerForPrecise_m)
			)
			
			if (length(recs) > 0) {
			
				these <- darwin[these, ]
				theseOut <- out[these, ]

				### NO rounded NO geospatial issues
				theseRecs <- recs[!theseOut$coordsRounded[recs] & !these$hasGeospatialIssues]
				if (length(theseRecs) > 0) {
				
					out$uncerType[theseRecs] <- 'precise'
					out$coordUncerBasedOn[theseRecs] <- 'coordinate uncertainty'
					
				}
				
				### NO rounded YES geospatial issues
				theseRecs <- recs[!theseOut$coordsRounded[recs] & these$hasGeospatialIssues]
			
				if (length(theseRecs) > 0) {
				
					out$uncerType[theseRecs] <- 'county'
					out$coordUncerArea_km2[theseRecs] <- out$areaOfCounty_km2[theseRecs]
					out$coordUncerBasedOn[theseRecs] <- 'county area'
					
				}
			
				### YES rounded NO geospatial issues
				theseRecs <- recs[theseOut$coordsRounded[recs] & !these$hasGeospatialIssues]
			
				if (length(theseRecs) > 0) {
				
					out$uncerType[theseRecs] <- 'county'
					out$coordUncerArea_km2[theseRecs] <- out$areaOfCounty_km2[theseRecs]
					out$coordUncerBasedOn[theseRecs] <- 'county area'
					
				}
			
				
			}

		### YES state YES county YES coords YES CU NO GSI rounded NO (all, precise)
		###########################################################################

			recs <- which(
				out$stateCountyMatches &
				!is.na(darwin$decimalLongitude) & !is.na(darwin$decimalLatitude) &
				!out$coordsRounded &
				out$coordUncerAugmented_m <= minCoordUncerForPrecise_m &
				!darwin$hasGeospatialIssues
			)
			
			if (length(recs) > 0) {
			
				out$uncerType[recs] <- 'precise'
				out$coordUncerArea_km2[recs] <- out$coordUncerAreaUsingCoords_km2[recs]
				out$coordUncerBasedOn[recs] <- 'stated coordinate uncertainty'
			
				
			}

		### YES state YES county YES coords YES CU YES GSI rounded NO (all, precise)
		############################################################################

			recs <- which(
				out$stateCountyMatches &
				!is.na(darwin$decimalLongitude) & !is.na(darwin$decimalLatitude) &
				!out$coordsRounded &
				out$coordUncerAugmented_m <= minCoordUncerForPrecise_m &
				darwin$hasGeospatialIssues
			)
			
			if (length(recs) > 0) {
			
				out$uncerType[recs] <- 'county'
				out$coordUncerArea_km2[recs] <- out$areaOfCounty_km2[recs]
				out$coordUncerBasedOn[recs] <- 'county area'
			
				
			}

		### YES state YES county YES coords YES CU NO GSI rounded YES (all, precise)
		############################################################################

			recs <- which(
				out$stateCountyMatches &
				!is.na(darwin$decimalLongitude) & !is.na(darwin$decimalLatitude) &
				out$coordsRounded &
				out$coordUncerAugmented_m <= minCoordUncerForPrecise_m &
				!darwin$hasGeospatialIssues
			)
			
			if (length(recs) > 0) {
			
				out$uncerType[recs] <- 'county'
				out$coordUncerArea_km2[recs] <- out$areaOfCounty_km2[recs]
				out$coordUncerBasedOn[recs] <- 'county area'
			
				
			}








	### NO state, NO county, NO coords, NO CU (all missing)
	### NO state, NO county, NO coords, YES CU - PRECISE (CU only, precise)
	### NO state, NO county, NO coords, YES CU - IMPRECISE (CU only, imprecise)
	###########################################################################

		recs <- which(
			is.na(darwin$stateProvince) &
			is.na(darwin$county) & 
			is.na(darwin$decimalLongitude) | is.na(darwin$decimalLatitude)
		)
		
		if (length(recs) > 0) {
		
			out$uncerType[recs] <- 'unusable'
			out$state[recs] <- NA
			out$county[recs] <- NA
			out$coordUncer_m[recs] <- NA
		
		}
	
	### NO state, NO county, YES coords, YES CU - PRECISE, NO GSI (coords, precise)
	### NO state, NO county, YES coords, YES CU - PRECISE, NO GSI (coords, precise, rounded 1)
	### NO state, NO county, YES coords, YES CU - PRECISE, NO GSI (coords, precise, rounded 0)
	##########################################################################################

		recs <- which(
			is.na(darwin$stateProvince) &
			is.na(darwin$county) &
			!is.na(darwin$decimalLongitude) &
			!is.na(darwin$decimalLatitude) &
			!is.na(darwin$coordinateUncertaintyInMeters) &
			!darwin$hasGeospatialIssues
		)

		if (length(recs) > 0) {
		
			these <- darwin[recs, ]
			where <- raster::extract(geogCounty, these[ , ll])

			# augment coordinate uncertainty by precision
			augmentedUncer_m <- augmentUncerByPrecis(these, roundedDigits)
			
			precise <- recs[which(augmentedUncer_m <= minCoordUncerForPrecise_m)]
			out$uncerType[precise] <- 'precise'
			out$state[precise] <- where[precise, stateGeogField]
			out$county[precise] <- where[precise, countyGeogField]
			out$coordUncer_m[precise] <- augmentedUncer_m[precise]
			
			imprecise <- recs[which(augmentedUncer_m > minCoordUncerForPrecise_m)]
			out$uncerType[imprecise] <- 'imprecise'
			out$state[imprecise] <- where[imprecise, stateGeogField]
			out$county[imprecise] <- where[imprecise, countyGeogField]
			out$coordUncer_m[imprecise] <- augmentedUncer_m[imprecise]
			
		}
	
	### NO state, NO county, YES coords, YES CU - PRECISE, YES GSI (coords, precise)
	### NO state, NO county, YES coords, YES CU - PRECISE, YES GSI (coords, precise, rounded 1)
	### NO state, NO county, YES coords, YES CU - PRECISE, YES GSI (coords, precise, rounded 0)
	###########################################################################################

		recs <- which(
			is.na(darwin$stateProvince) &
			is.na(darwin$county) &
			!is.na(darwin$decimalLongitude) &
			!is.na(darwin$decimalLatitude) &
			!is.na(darwin$coordinateUncertaintyInMeters) &
			darwin$hasGeospatialIssues
		)

		if (length(recs) > 0) {
		
			these <- darwin[recs, ]
			where <- raster::extract(geogCounty, these[ , ll])

			# augment coordinate uncertainty by precision
			augmentedUncer_m <- augmentUncerByPrecis(these, roundedDigits)
			
			sitesSp <- sp::SpatialPointsDataFrame(these[ , ll], data=these, proj4=unprojProj)
			sitesSpEa <- sp::spTransform(sites, eaProj)
			sitesBuffSpEa <- rgeos::gBuffer(sitesSpEa, byid=TRUE, width=augmentedUncer_m)
			theseUncerArea_km2 <- rgeos::gArea(sitesBuffSpEa, byid=TRUE) / 1000^2
			
			theseCountyArea_km2 <- 
			
			precise <- recs[which(augmentedUncer_m <= minCoordUncerForPrecise_m)]
			out$uncerType[precise] <- 'precise'
			out$state[precise] <- where[precise, stateGeogField]
			out$county[precise] <- where[precise, countyGeogField]
			out$coordUncer_m[precise] <- augmentedUncer_m[precise]
			
			imprecise <- recs[which(augmentedUncer_m > minCoordUncerForPrecise_m)]
			out$uncerType[imprecise] <- 'imprecise'
			out$state[imprecise] <- where[imprecise, stateGeogField]
			out$county[imprecise] <- where[imprecise, countyGeogField]
			out$coordUncer_m[imprecise] <- augmentedUncer_m[imprecise]
			
		}
	
	### NO state, NO county, YES coords, YES CU - PRECISE (coords, precise)
	### NO state, NO county, YES coords, YES CU - IMPRECISE (coords, imprecise)
	###########################################################################

		recs <- which(
			is.na(darwin$stateProvince) &
			is.na(darwin$county) &
			!is.na(darwin$decimalLongitude) &
			!is.na(darwin$decimalLatitude) &
			!is.na(darwin$coordinateUncertaintyInMeters) &
			naCompare('>', numCoordDigits, roundedDigits)
		)

		if (length(recs) > 0) {
		
			these <- darwin[recs, ]

			precise <- recs[which(these$coordinateUncertaintyInMeters <= minCoordUncerForPrecise_m)]
			out$uncerType[precise] <- 'precise'
			
			imprecise <- recs[which(these$coordinateUncertaintyInMeters > minCoordUncerForPrecise_m)]
			out$uncerType[imprecise] <- 'imprecise'

		}
	
	


coords, imprecise, rounded 1
coords, imprecise, rounded 0
coords only
coords only, rounded 1
coords only, rounded 0
county-only
county with precise CU
county with imprecise CU
county, coords, CU, precise
county, coords, CU, rounded 1
county, coords, CU, rounded 0
county, imprecise
county, imprecise, rounded 1
county, imprecise, rounded 0
county/coords
county/coords, rounded 1
county/coords, rounded 0
state-only
state, coords, precise
state, coords, precise, rounded 1
state, coords, precise, rounded 0
state, coords, imprecise
state, coords, imprecise, rounded 1
state, coords, imprecise, rounded 0
state/county only
state/county with precise CU
state/county with imprecise CU
all, precise
all, precise, rounded 1
all, precise, rounded 0
all, imprecise
all, imprecise, rounded 1
all, imprecise, rounded 0
state/county/coords
state/coords, not rounded
state/coords, rounded 1
state/coords, rounded 0
state with precise CU
state with imprecise CU



}
